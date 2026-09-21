# ============================================================================
# hw/sim/Makefile — build and run the RTL testbenches under Icarus Verilog
# ----------------------------------------------------------------------------
# Usage:
#   make            run every testbench, summarise pass/fail
#   make dot3       run one testbench
#   make vectors    regenerate stimulus from the golden model
#   make clean
#
# Vectors come from hw/golden/model.py, which is validated independently by its
# own self-test. The RTL is checked BIT-EXACT against them, which is only
# legitimate because the model commits to the same adder-tree shape as the RTL
# (IEEE-754 addition is not associative).
#
# If iverilog is not on PATH, install it or add it:
#   export PATH="$$HOME/.local/bin:$$PATH"
# ============================================================================

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python3

RTL_DIR  := ../rtl
TB_DIR   := ../tb
VEC_DIR  := ../tb/vectors
BUILD    := build

# -g2012 selects SystemVerilog-2012, which we need for always_ff, logic,
# queues and string. -Wall surfaces width mismatches, which are the most
# common source of silent hardware bugs.
IVFLAGS  := -g2012 -Wall -I$(RTL_DIR)

RTL := $(RTL_DIR)/delay_line.sv \
       $(RTL_DIR)/fp32_mul.sv \
       $(RTL_DIR)/fp32_add.sv \
       $(RTL_DIR)/dot3.sv \
       $(RTL_DIR)/rsqrt.sv \
       $(RTL_DIR)/pe_pair.sv \
       $(RTL_DIR)/pe_ray.sv \
       $(RTL_DIR)/accel_top.sv

TESTS := dot3 rsqrt pe_pair pe_ray accel_top

.PHONY: all clean vectors $(TESTS)

all: $(TESTS)
	@echo ""
	@echo "==================== SIMULATION SUMMARY ===================="
	@fail=0; \
	for t in $(TESTS); do \
	  if grep -q "PASS" $(BUILD)/$$t.log 2>/dev/null; then \
	    echo "  PASS  tb_$$t"; \
	  else \
	    echo "  FAIL  tb_$$t"; fail=1; \
	  fi; \
	done; \
	echo "==========================================================="; \
	if [ $$fail -ne 0 ]; then echo "AT LEAST ONE TESTBENCH FAILED"; exit 1; \
	else echo "ALL TESTBENCHES PASSED"; fi

# Stimulus + the rsqrt seed table. The LUT must sit where the simulation's cwd
# can find it, because rsqrt.sv does $readmemh("rsqrt_lut.hex").
vectors:
	cd ../.. && $(PYTHON) hw/golden/model.py --vectors

$(BUILD):
	mkdir -p $(BUILD)

# Each testbench runs with cwd = hw/tb so relative vector paths resolve, and we
# copy the LUT next to it for $readmemh.
define RUN_TB
$(1): $(BUILD) $(RTL) $(TB_DIR)/tb_$(1).sv
	@echo "--- compiling tb_$(1) ---"
	$(IVERILOG) $(IVFLAGS) -o $(BUILD)/tb_$(1).vvp $(RTL) $(TB_DIR)/tb_$(1).sv
	@cp -f $(VEC_DIR)/rsqrt_lut.hex $(TB_DIR)/rsqrt_lut.hex 2>/dev/null || true
	@echo "--- running tb_$(1) ---"
	@cd $(TB_DIR) && $(VVP) ../sim/$(BUILD)/tb_$(1).vvp \
	    2>&1 | tee ../sim/$(BUILD)/$(1).log
endef

$(foreach t,$(TESTS),$(eval $(call RUN_TB,$(t))))

clean:
	rm -rf $(BUILD) $(TB_DIR)/rsqrt_lut.hex $(TB_DIR)/*.vcd
