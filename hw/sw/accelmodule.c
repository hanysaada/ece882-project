/* ==========================================================================
 * accelmodule.c — CPython C extension exposing the dot3 + rsqrt accelerator
 * --------------------------------------------------------------------------
 * WHY A C EXTENSION AND NOT ctypes
 * We measured the boundary (results/hw/call_overhead.txt):
 *
 *     ctypes call, 3 double arguments   595.0 ns
 *     math.sqrt (a C builtin)            41.2 ns
 *
 * ctypes marshals arguments through libffi on every call, which is why it is an
 * order of magnitude slower than a hand-written extension. Since the whole
 * argument for this accelerator is that the crossing must be cheap and rare, the
 * driver has to be a real extension, not ctypes. That is a decision the
 * MEASUREMENT forced, not a style preference.
 *
 * WHAT THIS MODULE DOES
 *   accel.nbody_step(buf, n_bodies, dt, n_steps)
 *       buf is a writable buffer of n_bodies * 8 float32 words, laid out
 *       x y z vx vy vz mass pad -- exactly accel_top.sv's documented layout.
 *       ONE call runs n_steps timesteps. That is the point: the crossing is paid
 *       once per batch, not once per pair.
 *
 *   accel.ray_intersect(cp_buf, rv_buf, r2_buf, out_t, out_hit, count)
 *       batched ray/sphere intersection, one crossing for `count` tests.
 *
 *   accel.have_device()   -> True if a real accelerator was mapped
 *   accel.backend()       -> "mmio" or "software-model"
 *
 * THREE EXECUTION PATHS, in order of preference
 *   1. MMIO: if ACCEL_DEV names a device file, mmap its CSR window, write the
 *      descriptor, kick START, poll STATUS.DONE. This is the real path.
 *   2. Software model: compute the SAME arithmetic in C float, bit-for-bit
 *      matching hw/golden/model.py. Used when no device is present, which is
 *      always the case for this project since we have no silicon.
 *   3. accel.py falls back to pure Python if even this extension is missing.
 *
 * Path 2 matters for the assignment: it lets the benchmark run end to end and
 * lets the equivalence test prove the interface is correct, without pretending
 * hardware exists. Never report path 2 timings as accelerator performance --
 * backend() exists precisely so a caller cannot confuse them.
 * ========================================================================== */

#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

/* ---- CSR map, must match accel_top.sv ---------------------------------- */
#define CSR_CTRL      0x00
#define CSR_STATUS    0x04
#define CSR_BODY_PTR  0x08
#define CSR_N_BODIES  0x0C
#define CSR_DT        0x10
#define CSR_N_STEPS   0x14
#define CSR_PAIRS     0x18
#define CSR_CYCLES    0x1C

#define CTRL_START    (1u << 0)
#define CTRL_IRQ_EN   (1u << 1)
#define STATUS_DONE   (1u << 0)
#define STATUS_BUSY   (1u << 1)
#define STATUS_ERR    (1u << 2)

#define CSR_WINDOW    4096

static volatile uint32_t *g_csr = NULL;   /* NULL => no device */
static int   g_fd = -1;

/* ---- rsqrt software model ----------------------------------------------
 * Mirrors hw/rtl/rsqrt.sv exactly: exponent split, 64-entry Q2.14 seed table,
 * two Newton-Raphson iterations, every intermediate rounded to float. The table
 * is built at import time by the same formula the golden model uses, so the
 * three implementations (Python model, SystemVerilog, this C) cannot drift.
 * -------------------------------------------------------------------------- */
#define LUT_BITS 6
#define LUT_N    (1 << LUT_BITS)
#define NR_ITERS 2

static uint16_t g_lut[LUT_N];

static void build_lut(void)
{
    int half = 1 << (LUT_BITS - 1);
    for (int parity = 0; parity < 2; parity++) {
        for (int j = 0; j < half; j++) {
            double lo, hi;
            double man_lo = (double)j / half;
            double man_hi = (double)(j + 1) / half;
            if (parity == 0) { lo = 1.0 + man_lo;       hi = 1.0 + man_hi; }
            else             { lo = 2.0 + 2.0 * man_lo; hi = 2.0 + 2.0 * man_hi; }
            double mid = 0.5 * (lo + hi);
            g_lut[(parity << (LUT_BITS - 1)) | j] =
                (uint16_t)(1.0 / sqrt(mid) * 16384.0 + 0.5);
        }
    }
}

static float model_rsqrt(float x)
{
    uint32_t bits;
    memcpy(&bits, &x, 4);
    int      exp_field = (int)((bits >> 23) & 0xFF);
    uint32_t man       = bits & 0x7FFFFF;
    int      E         = exp_field - 127;

    int parity = E & 1;
    int k      = (E - parity) >> 1;
    int idx    = (parity << (LUT_BITS - 1)) | (int)(man >> (23 - (LUT_BITS - 1)));

    float y = (float)ldexp((double)g_lut[idx] / 16384.0, -k);

    for (int i = 0; i < NR_ITERS; i++) {
        float y2  = y * y;             /* each op is float: matches the RTL */
        float xy2 = x * y2;
        float t   = 1.5f - 0.5f * xy2;
        y = y * t;
    }
    return y;
}

/* dot3 with the SAME adder-tree shape as dot3.sv: ((p0+p1)+p2).
 * IEEE-754 addition is not associative, so the shape is part of the spec. */
static float model_dot3(float ax, float ay, float az,
                        float bx, float by, float bz)
{
    float p0 = ax * bx, p1 = ay * by, p2 = az * bz;
    float s01 = p0 + p1;
    return s01 + p2;
}

/* ---- MMIO path ---------------------------------------------------------- */
static int try_open_device(void)
{
    const char *dev = getenv("ACCEL_DEV");
    if (!dev || !*dev) return 0;
    g_fd = open(dev, O_RDWR | O_SYNC);
    if (g_fd < 0) return 0;
    void *p = mmap(NULL, CSR_WINDOW, PROT_READ | PROT_WRITE, MAP_SHARED, g_fd, 0);
    if (p == MAP_FAILED) { close(g_fd); g_fd = -1; return 0; }
    g_csr = (volatile uint32_t *)p;
    return 1;
}

static int mmio_nbody_step(uint64_t phys, uint32_t n_bodies,
                           float dt, uint32_t n_steps, char **err)
{
    uint32_t dtb;
    memcpy(&dtb, &dt, 4);
    g_csr[CSR_BODY_PTR / 4] = (uint32_t)phys;
    g_csr[CSR_N_BODIES / 4] = n_bodies;
    g_csr[CSR_DT       / 4] = dtb;
    g_csr[CSR_N_STEPS  / 4] = n_steps;
    g_csr[CSR_CTRL     / 4] = CTRL_START;

    /* Poll. A real driver would take the interrupt instead; polling is correct
     * but burns a core, and at these run lengths (a full nbody batch is
     * milliseconds) an interrupt is clearly the right choice. Documented rather
     * than silently chosen. */
    for (long i = 0; i < 100000000L; i++) {
        uint32_t st = g_csr[CSR_STATUS / 4];
        if (st & STATUS_ERR)  { *err = "accelerator reported STATUS.ERR"; return -1; }
        if (st & STATUS_DONE) return 0;
    }
    *err = "timed out waiting for STATUS.DONE";
    return -1;
}

/* ---- software model of one timestep ------------------------------------
 * Structure copied from accel_top.sv, INCLUDING the choices that exist only
 * because of hardware constraints, because they change the float result:
 *   - i outer, all j != i inner, force on i only (no Newton's third law): the
 *     hardware cannot accumulate onto both bodies of a pair without a
 *     read-after-write hazard on in-flight state.
 *   - NPART partial accumulators reduced as (p0+p1)+(p2+p3): the hardware needs
 *     them to cover the adder's 3-cycle latency without stalling.
 * Simplifying either would make this model disagree with the RTL in the last
 * bits, and then it would not be a model.
 * -------------------------------------------------------------------------- */
#define NPART 4

static void model_step(float *b, uint32_t n, float dt)
{
    for (uint32_t i = 0; i < n; i++) {
        float *bi = b + (size_t)i * 8;
        float px[NPART] = {0}, py[NPART] = {0}, pz[NPART] = {0};
        int k = 0;
        for (uint32_t j = 0; j < n; j++) {
            if (j == i) continue;
            float *bj = b + (size_t)j * 8;
            float dx = bi[0] - bj[0];
            float dy = bi[1] - bj[1];
            float dz = bi[2] - bj[2];
            float d2 = model_dot3(dx, dy, dz, dx, dy, dz);
            float r  = model_rsqrt(d2);
            float r3 = (r * r) * r;
            float mag = dt * r3;
            float b2m = bj[6] * mag;          /* the OTHER body's mass */
            px[k] += -(dx * b2m);
            py[k] += -(dy * b2m);
            pz[k] += -(dz * b2m);
            k = (k + 1) % NPART;
        }
        float sx = (px[0] + px[1]) + (px[2] + px[3]);
        float sy = (py[0] + py[1]) + (py[2] + py[3]);
        float sz = (pz[0] + pz[1]) + (pz[2] + pz[3]);
        bi[3] += sx;
        bi[4] += sy;
        bi[5] += sz;
    }
    for (uint32_t i = 0; i < n; i++) {
        float *bi = b + (size_t)i * 8;
        bi[0] += dt * bi[3];
        bi[1] += dt * bi[4];
        bi[2] += dt * bi[5];
    }
}

/* ---- Python entry points ------------------------------------------------ */

static PyObject *py_nbody_step(PyObject *self, PyObject *args)
{
    Py_buffer view;
    unsigned int n_bodies, n_steps;
    double dt_d;

    if (!PyArg_ParseTuple(args, "w*IdI", &view, &n_bodies, &dt_d, &n_steps))
        return NULL;

    if (view.len < (Py_ssize_t)((size_t)n_bodies * 8 * sizeof(float))) {
        PyBuffer_Release(&view);
        PyErr_SetString(PyExc_ValueError,
                        "buffer too small: need n_bodies * 8 float32 words");
        return NULL;
    }

    float *b = (float *)view.buf;
    float  dt = (float)dt_d;

    if (g_csr) {
        char *err = NULL;
        /* A real driver would translate to a DMA-able physical address here.
         * We do not fabricate one: without a device this path is unreachable. */
        int rc = mmio_nbody_step((uint64_t)(uintptr_t)b, n_bodies, dt, n_steps, &err);
        PyBuffer_Release(&view);
        if (rc != 0) { PyErr_SetString(PyExc_RuntimeError, err); return NULL; }
        Py_RETURN_NONE;
    }

    /* software model path */
    Py_BEGIN_ALLOW_THREADS
    for (unsigned int s = 0; s < n_steps; s++) model_step(b, n_bodies, dt);
    Py_END_ALLOW_THREADS

    PyBuffer_Release(&view);
    Py_RETURN_NONE;
}

static PyObject *py_ray_intersect(PyObject *self, PyObject *args)
{
    Py_buffer cp, rv, r2, ot, oh;
    unsigned int count;

    if (!PyArg_ParseTuple(args, "y*y*y*w*w*I", &cp, &rv, &r2, &ot, &oh, &count))
        return NULL;

    const float *pc = (const float *)cp.buf;
    const float *pr = (const float *)rv.buf;
    const float *p2 = (const float *)r2.buf;
    float       *pt = (float *)ot.buf;
    uint8_t     *ph = (uint8_t *)oh.buf;

    Py_BEGIN_ALLOW_THREADS
    for (unsigned int i = 0; i < count; i++) {
        float cx = pc[3*i], cy = pc[3*i+1], cz = pc[3*i+2];
        float vx = pr[3*i], vy = pr[3*i+1], vz = pr[3*i+2];
        float v  = model_dot3(cx, cy, cz, vx, vy, vz);
        float cc = model_dot3(cx, cy, cz, cx, cy, cz);
        float v2 = v * v;
        float s1 = cc - v2;
        float disc = p2[i] - s1;
        if (disc < 0.0f) {
            /* mirror pe_ray.sv: feed 1.0 to rsqrt so it never sees a negative,
             * and report the miss out of band rather than returning a number
             * the caller might use. */
            (void)model_rsqrt(1.0f);
            ph[i] = 0;
            pt[i] = 0.0f;
        } else {
            float rs = model_rsqrt(disc);
            float sq = disc * rs;
            pt[i] = v - sq;
            ph[i] = 1;
        }
    }
    Py_END_ALLOW_THREADS

    PyBuffer_Release(&cp); PyBuffer_Release(&rv); PyBuffer_Release(&r2);
    PyBuffer_Release(&ot); PyBuffer_Release(&oh);
    Py_RETURN_NONE;
}

static PyObject *py_have_device(PyObject *self, PyObject *args)
{
    if (g_csr) Py_RETURN_TRUE;
    Py_RETURN_FALSE;
}

static PyObject *py_backend(PyObject *self, PyObject *args)
{
    return PyUnicode_FromString(g_csr ? "mmio" : "software-model");
}

static PyObject *py_perf_counters(PyObject *self, PyObject *args)
{
    if (!g_csr) {
        PyErr_SetString(PyExc_RuntimeError,
                        "no device: performance counters are hardware registers");
        return NULL;
    }
    return Py_BuildValue("(II)", g_csr[CSR_PAIRS / 4], g_csr[CSR_CYCLES / 4]);
}

/* Exposed for the equivalence test: the primitives on their own. */
static PyObject *py_rsqrt(PyObject *self, PyObject *args)
{
    double x;
    if (!PyArg_ParseTuple(args, "d", &x)) return NULL;
    return PyFloat_FromDouble((double)model_rsqrt((float)x));
}

static PyObject *py_dot3(PyObject *self, PyObject *args)
{
    double ax, ay, az, bx, by, bz;
    if (!PyArg_ParseTuple(args, "dddddd", &ax, &ay, &az, &bx, &by, &bz))
        return NULL;
    return PyFloat_FromDouble((double)model_dot3(
        (float)ax, (float)ay, (float)az, (float)bx, (float)by, (float)bz));
}

static PyMethodDef methods[] = {
    {"nbody_step",    py_nbody_step,    METH_VARARGS,
     "nbody_step(buf, n_bodies, dt, n_steps) -- run n_steps timesteps"},
    {"ray_intersect", py_ray_intersect, METH_VARARGS,
     "ray_intersect(cp, rv, r2, out_t, out_hit, count) -- batched intersection"},
    {"have_device",   py_have_device,   METH_NOARGS,  "True if a device is mapped"},
    {"backend",       py_backend,       METH_NOARGS,  "'mmio' or 'software-model'"},
    {"perf_counters", py_perf_counters, METH_NOARGS,  "(pairs, cycles) from CSRs"},
    {"rsqrt",         py_rsqrt,         METH_VARARGS, "single rsqrt, for testing"},
    {"dot3",          py_dot3,          METH_VARARGS, "single dot3, for testing"},
    {NULL, NULL, 0, NULL}
};

static struct PyModuleDef moduledef = {
    PyModuleDef_HEAD_INIT, "_accel",
    "dot3 + rsqrt accelerator driver, with a bit-accurate software model",
    -1, methods
};

PyMODINIT_FUNC PyInit__accel(void)
{
    build_lut();
    (void)try_open_device();          /* absence of a device is not an error */
    return PyModule_Create(&moduledef);
}
