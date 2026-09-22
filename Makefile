# Makefile per la simulazione con QuestaSim / ModelSim

# Eseguibili di QuestaSim
VLIB = vlib
VLOG = vlog
VSIM = vsim

# Nome della libreria di lavoro e del modulo Top del Testbench
WORK_DIR = work
TB_NAME  = top_module_tb

# Elenco dei file sorgente SystemVerilog
# Modificare se i nomi dei file effettivi sono diversi
SRC = a_buffer.sv b_buffer.sv c_buffer.sv colID_buffer.sv row_ptr_buffer.sv datapath.sv mac_int8.sv scheduler.sv top_module.sv top_module_tb.sv

# Target predefinito: crea la libreria, compila e avvia la simulazione in batch (CLI)
all: compile sim

# Creazione della libreria di lavoro
$(WORK_DIR):
	$(VLIB) $(WORK_DIR)

# Compilazione dei file sorgente (flag -sv per SystemVerilog)
compile: $(WORK_DIR)
	$(VLOG) -sv $(SRC)

# Simulazione in modalità Command Line (CLI)
sim: compile
	$(VSIM) -c -voptargs="+acc" $(TB_NAME) -do "run -all; quit"

# Simulazione in modalità Grafica (GUI) con aggiunta automatica delle onde
gui: compile
	$(VSIM) -voptargs="+acc" $(TB_NAME) -do "add wave -r /*; run -all"

# Pulizia dei file generati da QuestaSim
clean:
	rm -rf $(WORK_DIR) transcript modelsim.ini vsim.wlf *.log
