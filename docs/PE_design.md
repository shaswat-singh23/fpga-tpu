# Processing Element (PE) Design

## Overview

Each processing element within the systolic array is responsible for computing the product of the two data elements it's given, adding that to its private accumulated sum, and passing along the appropriate data elements to its neighbors.

## Interface

### Parameters
| Name | Default | Description |
|---|---|---|
| `DATA_WIDTH` | 8 | Bit width of input operands (A, B elements) |
| `ACC_WIDTH` | 32 | Bit width of accumulator (prevents overflow) |

### Ports
| Name | Direction | Width | Description |
|---|---|---|---|
| `clk` | input | 1 | Clock signal |
| `reset` | input | 1 | Synchronous reset |
| `a_in` | input | DATA_WIDTH | Element of matrix A from left neighbor |
| `b_in` | input | DATA_WIDTH | Element of matrix B from top neighbor |
| `a_out` | output | DATA_WIDTH | Pass-through of a_in to right neighbor (registered) |
| `b_out` | output | DATA_WIDTH | Pass-through of b_in to bottom neighbor (registered) |
| `result` | output | ACC_WIDTH | Running accumulated value |

## Behavior

In each clock cycle, a PE receives a single element of A and B. It then multiplies them together and adds that to its accumulated sum. Then, it takes those same two elements and passes them along to its two neighbors. On reset, the output registers and accumulator are set to 0.

## Design Decisions

While weight stationary can be more efficient when doing repeated tests with one of the elements being the same, as is the case with LLM inference, I will initially be testing with various different matrices, making an output stationary model necessary. It's also simpler to design, so I will start off with it with possibility of including weight stationary functionality if time allows. These specific widths were chosen to give a baseline to verify system functionality on, and will be scaled up later. Once again, the current bit width is set just for testing and will be scaled up later. The accumulator width is set high just to have plenty of extra headroom as I scale up without needing to readjust every time.