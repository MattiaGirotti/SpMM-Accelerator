# Makefile per la simulazione con QuestaSim / ModelSim

VLIB = vlib
VLOG = vlog
VSIM = vsim

WORK_DIR = work
TB_NAME  = top_module_tb

# Elenco aggiornato dei file sorgente SystemVerilog (incluso il front-end HWPE-Ctrl e regif)
SRC = \
    hwpe_stream_package.sv \
    hwpe_ctrl_package.sv \
    hwpe_ctrl_intf_periph.sv \
    hci_package.sv \
    hci_interfaces.sv \
    spmm_pkg.sv \
    regif/spmm_regif_pkg.sv \
    regif/spmm_regif.sv \
    spmm_target_decoder.sv \
    hwpe_ctrl_target.sv \
    assertions.svh \
    registers.svh \
	cc_pkg.sv \
	cc_fifo.sv \
	fifo_v3.sv \
    a_buffer.sv \
    b_buffer.sv \
    c_buffer.sv \
    colID_buffer.sv \
    row_ptr_buffer.sv \
    mac_int8.sv \
    datapath.sv \
    scheduler.sv \
    streamer.sv \
    top_module.sv \
    top_module_tb.sv

all: compile sim

$(WORK_DIR):
	$(VLIB) $(WORK_DIR)

# Compilazione dei sorgenti e inclusione della directory corrente per i file .svh / pacchetti (-incdir .)
compile: $(WORK_DIR)
	$(VLOG) -sv -incdir . -incdir regif/ $(SRC)

sim: compile
	$(VSIM) -c -voptargs="+acc" $(TB_NAME) -do "run -all; quit"

gui: compile
	$(VSIM) -voptargs="+acc" $(TB_NAME) -do "add wave -r /*; run -all"

clean:
	rm -rf $(WORK_DIR) transcript modelsim.ini vsim.wlf *.log