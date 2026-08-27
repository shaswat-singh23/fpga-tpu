# Custom MNIST Model Running on Hardware

Reference doc for the ML side of the MNIST demo. Covers the model,
how it gets quantized to run on the accelerator, and what each file
in `mnist/` does. See `docs/accelerator_plan.md` for the hardware ISA
this pipeline targets.

---

## Model

A 784 to 64 to 64 to 10 MLP, trained from scratch in numpy, no
framework. Two hidden layers, ReLU activation, no softmax on the
output (the accelerator produces raw logits, softmax is not
implemented in hardware, and argmax on raw logits gives the same
prediction as argmax on softmax output).

Trained with full batch gradient descent on MNIST, using
`sklearn.fetch_openml` for the dataset. Held out 1000 examples as a
dev set. Reaches about 91 percent accuracy on held-out data.

See `mnist/mnist_from_scratch/train.py`.

---

## Why quantize

The accelerator's PEs are 8-bit signed multiply-accumulate units,
matching the TPU v1 reference design. A model trained in float32 has
to be converted to int8 weights, biases, and activations before it
can run on hardware. This is standard post-training quantization
(PTQ), not something specific to this project.

---

## Quantization scheme

Each weight matrix gets its own per-neuron scale factor, computed as
the max absolute value in that neuron's row divided by 127. This uses
the full int8 range per neuron rather than one scale for the whole
matrix.

Activations get requantized between layers through the QUANTIZE
instruction, which computes `(value * M) >> shift` per neuron, clamped
to int8 range. M is an 8-bit unsigned value per neuron, shift is one
shared value for the whole layer. Both are solved by sweeping every
possible shift (0 to 31), computing the best M for each, and picking
whichever shift gives the lowest total error across the layer.

The final layer has no QUANTIZE step. Its raw int32 accumulator
output goes straight to STORE_C, and argmax happens on the host side.

See `mnist/mnist_from_scratch/export.py`.

---

## Bias clipping

The hardware adds bias directly into the int32 accumulator as a
sign-extended int8 value, with no separate scale for bias. That means
bias has to be pre-expressed in the accumulator's own scale
(`weight_scale * input_scale`) before quantizing, and that scale is
usually a small number, so ordinary trained bias values can end up
needing far more than 8 bits to represent.

This actually happened. Before any fix, biases needed up to about
16,600 in magnitude, when int8 only holds up to 127. Almost every
bias value was clipping.

The fix was L2 regularization on the bias terms during training, not
a post hoc scale-down after the fact. Adding a penalty proportional to
bias magnitude into the gradient pushes training toward a solution
that uses smaller biases without being told which values to use.
After tuning the regularization strength, every bias fit under
magnitude 33, well inside int8 range, and accuracy did not change.
This means the fix was free: not a real tradeoff, since the model
found an equally good solution that also happens to quantize cleanly.

---

## Golden model

A pure numpy implementation of the hardware's exact int8/int32
arithmetic. Same multiply-accumulate, same accumulator width, same
per-neuron requantization math as the RTL. This is the actual
correctness bar for the whole pipeline, not training accuracy, since
training accuracy only proves the float model works. Matching the
golden model bit-for-bit proves the quantization and the hardware
both do the right thing.

One shortcut worth noting: the golden model computes each layer's
matmul as one full dot product instead of simulating the hardware's
13 separate K-tile accumulate calls for layer 1. This is safe because
int32 addition is exact at these magnitudes (no overflow risk), so
the two are guaranteed to produce identical results.

See `mnist/mnist_from_scratch/golden_model.py`.

---

## File map

| File | Role |
|------|------|
| `train.py` | Loads MNIST, defines the network, trains it, saves weights to `mnist_weights_final.npz` |
| `evaluate.py` | Loads saved weights, checks accuracy without retraining |
| `export.py` | Loads trained weights, computes quantization scales, solves M/shift per layer, writes `mnist_quantized.npz` and the C headers the hardware driver includes |
| `golden_model.py` | Bit-exact hardware arithmetic in numpy, used to validate hardware output |