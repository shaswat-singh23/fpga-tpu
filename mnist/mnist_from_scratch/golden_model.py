import numpy as np
from sklearn.datasets import fetch_openml

q = np.load('mnist_quantized.npz')
W1, b1 = q['W1_q'].astype(np.int32), q['b1_q'].astype(np.int32)
W2, b2 = q['W2_q'].astype(np.int32), q['b2_q'].astype(np.int32)
W3, b3 = q['W3_q'].astype(np.int32), q['b3_q'].astype(np.int32)
l1_M, l1_shift = q['l1_M'].astype(np.int64), int(q['l1_shift'])
l2_M, l2_shift = q['l2_M'].astype(np.int64), int(q['l2_shift'])
input_scale = float(q['input_scale'])

def relu_activate(acc, bias):
    # matches activate_unit.sv: bias sign-extended int8 added straight into
    # the int32 accumulator, then ReLU
    s = acc + bias[:, None]
    return np.maximum(s, 0)

def quantize(acc, M, shift):
    # matches quantize_unit.sv: c_val(int32) * m_val(uint8, unsigned) -> signed
    # product, arithmetic right shift, clamp to int8
    product = acc.astype(np.int64) * M[:, None]
    shifted = product >> shift  # arithmetic shift on signed ints in numpy int64
    return np.clip(shifted, -128, 127).astype(np.int32)

def golden_forward(X_int8):
    # layer 1: K-tiled accumulate in hardware (13 chunks of 64) is
    # mathematically identical to one full 832-term dot product here --
    # int32 addition is exact for these magnitudes (max term 127*127=16129,
    # summed over 832 terms ~= 13.4M, nowhere near int32 overflow), so no
    # difference between "13 accumulated MATMUL calls" and "one matmul" here
    Z1 = W1 @ X_int8.astype(np.int32)          # (64, batch)
    A1 = relu_activate(Z1, b1)
    A1_q = quantize(A1, l1_M, l1_shift)         # int8 input to layer 2

    Z2 = W2 @ A1_q
    A2 = relu_activate(Z2, b2)
    A2_q = quantize(A2, l2_M, l2_shift)         # int8 input to layer 3

    Z3 = W3 @ A2_q
    out = Z3 + b3[:, None]                      # raw int32, no ReLU/quantize --
    return out                                  # matches straight-to-STORE_C path

def pixels_to_int8(X_float01, pad_to=832):
    Xq = np.round(X_float01 / input_scale)
    Xq = np.clip(Xq, 0, 127).astype(np.int32)
    padded = np.zeros((pad_to, Xq.shape[1]), dtype=np.int32)
    padded[:Xq.shape[0], :] = Xq
    return padded

if __name__ == '__main__':
    mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='liac-arff')
    X, y = mnist.data, mnist.target.astype(int)

    np.random.seed(67)
    perm = np.random.permutation(X.shape[0])
    X_shuf, y_shuf = X[perm], y[perm]

    batch = 64
    X_batch = (X_shuf[:batch].T) / 255.
    Y_batch = y_shuf[:batch]

    X_int8 = pixels_to_int8(X_batch)
    logits = golden_forward(X_int8)             # (64, batch), only first 10 rows real
    preds = np.argmax(logits[:10, :], axis=0)

    correct = np.sum(preds == Y_batch)
    print(f"golden model: {correct}/{batch} correct")
    print("predictions:", preds)
    print("labels:     ", Y_batch)

    # float-model accuracy on the IDENTICAL 64 examples, for a fair
    # apples-to-apples comparison against quantized accuracy
    def relu(Z): return np.maximum(Z, 0)
    def softmax(Z):
        e = np.exp(Z - np.max(Z, axis=0, keepdims=True))
        return e / np.sum(e, axis=0, keepdims=True)

    train_w = np.load('mnist_weights.npz')
    W1f, b1f = train_w['W1'], train_w['b1']
    W2f, b2f = train_w['W2'], train_w['b2']
    W3f, b3f = train_w['W3'], train_w['b3']

    Z1f = W1f @ X_batch + b1f
    A1f = relu(Z1f)
    Z2f = W2f @ A1f + b2f
    A2f = relu(Z2f)
    Z3f = W3f @ A2f + b3f
    float_preds = np.argmax(softmax(Z3f), axis=0)
    float_correct = np.sum(float_preds == Y_batch)
    print(f"float model, SAME batch: {float_correct}/{batch} correct")