# Makefile per la simulazione con QuestaSim / ModelSim

VLIB = vlib
VLOG = vlog
VSIM = vsim

WORK_DIR = work
TB_NAME  = top_module_tb

# Elenco dei file sorgente SystemVerilog (hci_interfaces.sv contiene hci_core_intf)
SRC = hwpe_stream_package.sv hci_package.sv hci_interfaces.sv a_buffer.sv b_buffer.sv c_buffer.sv colID_buffer.sv row_ptr_buffer.sv datapath.sv mac_int8.sv scheduler.sv streamer.sv top_module.sv top_module_tb.sv

all: compile sim

$(WORK_DIR):
	$(VLIB) $(WORK_DIR)

# Compilazione dei sorgenti e inclusione della directory corrente per i file .svh (-incdir .)
compile: $(WORK_DIR)
	$(VLOG) -sv -incdir . $(SRC)

sim: compile
	$(VSIM) -c -voptargs="+acc" $(TB_NAME) -do "run -all; quit"

gui: compile
	$(VSIM) -voptargs="+acc" $(TB_NAME) -do "add wave -r /*; run -all"

clean:
	rm -rf $(WORK_DIR) transcript modelsim.ini vsim.wlf *.log