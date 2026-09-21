"""Build the _accel extension:  python3 setup.py build_ext --inplace"""
from setuptools import setup, Extension

setup(
    name="accel",
    version="1.0.0",
    ext_modules=[Extension("_accel", sources=["accelmodule.c"],
                           extra_compile_args=["-O2", "-Wall"])],
    py_modules=["accel"],
)
