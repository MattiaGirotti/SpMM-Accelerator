#!/bin/bash
# Copyright 2025 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

peakrdl regblock  spmm_regif.rdl -o regif/ --cpuif passthrough --default-reset arst_n --hwif-report --addr-width 32
peakrdl html      spmm_regif.rdl -o regif/html/
peakrdl c-header  spmm_regif.rdl -o ../../sw/spmm_ctrl_target.h

awk '
  /#include <assert.h>/ {
    print
    print ""
    print "#if defined(__cplusplus)"
    print "#define SPMM_STATIC_ASSERT(cond, msg) static_assert(cond, msg)"
    print "#elif defined(__STDC_VERSION__) && (__STDC_VERSION__ >= 201112L)"
    print "#define SPMM_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)"
    print "#else"
    print "#define SPMM_STATIC_ASSERT_CONCAT_(a, b) a##b"
    print "#define SPMM_STATIC_ASSERT_CONCAT(a, b) SPMM_STATIC_ASSERT_CONCAT_(a, b)"
    print "#define SPMM_STATIC_ASSERT(cond, msg) \\"
    print "  typedef char SPMM_STATIC_ASSERT_CONCAT(spmm_static_assert_, __LINE__)[(cond) ? 1 : -1]"
    print "#endif"
    next
  }
  {
    gsub(/static_assert\(/, "SPMM_STATIC_ASSERT(")
    print
  }
' ../../sw/spmm_ctrl_target.h > ../../sw/spmm_ctrl_target.h.tmp && mv ../../sw/spmm_ctrl_target.h.tmp ../../sw/spmm_ctrl_target.h

# PeakRDL usa struct unpacked per default; le convertiamo in packed per renderle compatibili con le code FIFO dell'HWPE
sed -E 's/typedef[[:space:]]+struct([[:space:]])/typedef struct packed\1/g' regif/spmm_regif_pkg.sv > regif/spmm_regif_pkg.sv.tmp && mv regif/spmm_regif_pkg.sv.tmp regif/spmm_regif_pkg.sv

# Aggiunta dell'intestazione di licenza SPDX in cima ai file generati
HEADER='// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51'

for f in regif/spmm_regif.sv regif/spmm_regif_pkg.sv ../../sw/spmm_ctrl_target.h; do
  printf '%s\n' "$HEADER" | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"
done