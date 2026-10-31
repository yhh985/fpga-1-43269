


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Parenthesize macro arithmetic: without this, textual substitution made
// SELF_REFRESH_INTERVAL evaluate to zero and disabled periodic refresh.
// C1/C2 now run at 1 GHz / 24 = 41.666667 MHz, exactly 24 ns per cycle.
`define   SDR_CLK_PERIOD                    (24)
// init_cnt includes both zero and this terminal value before returning to
// zero. Subtract one so a whole refresh sweep does not exceed 64 ms.
`define   SELF_REFRESH_INTERVAL             ((64000000 / `SDR_CLK_PERIOD / (2 ** `ROW_WIDTH)) - 1)

