import numpy as np
from sklearn.datasets import fetch_openml

weights = np.load('mnist_weights.npz')
W1, b1 = weights['W1'], weights['b1']
W2, b2 = weights['W2'], weights['b2']
W3, b3 = weights['W3'], weights['b3']

mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='liac-arff')
X, y = mnist.data, mnist.target.astype(int)
X_sample = (X[:2000].T) / 255.

def ReLU(Z):
    return np.maximum(Z, 0)

def softmax(Z):
    expZ = np.exp(Z - np.max(Z, axis=0, keepdims=True))
    return expZ / np.sum(expZ, axis=0, keepdims=True)

Z1 = W1.dot(X_sample) + b1
A1 = ReLU(Z1)
Z2 = W2.dot(A1) + b2
A2 = ReLU(Z2)
Z3 = W3.dot(A2) + b3
A3 = softmax(Z3)

INPUT_SCALE = 1.0 / 127.0

def weight_scale_per_neuron(W):
    return np.max(np.abs(W), axis=1) / 127.0

w1_scale = weight_scale_per_neuron(W1)
w2_scale = weight_scale_per_neuron(W2)
w3_scale = weight_scale_per_neuron(W3)

l1_output_scale = np.max(np.abs(A1)) / 127.0
l2_output_scale = np.max(np.abs(A2)) / 127.0

def quantize_weights(W, w_scale):
    Wq = np.round(W / w_scale[:, None])
    return np.clip(Wq, -127, 127).astype(np.int8)

W1_q = quantize_weights(W1, w1_scale)
W2_q = quantize_weights(W2, w2_scale)
W3_q = quantize_weights(W3, w3_scale)

def quantize_bias(b, w_scale, in_scale):
    bias_scale = w_scale * in_scale
    bq = np.round(b.flatten() / bias_scale)
    return np.clip(bq, -127, 127).astype(np.int8)

b1_q = quantize_bias(b1, w1_scale, INPUT_SCALE)
b2_q = quantize_bias(b2, w2_scale, l1_output_scale)
b3_q = quantize_bias(b3, w3_scale, l2_output_scale)

def solve_quantize_params(w_scale, in_scale, out_scale, shift_range=range(0, 32)):
    target = (w_scale * in_scale) / out_scale
    best_shift, best_err, best_M = None, np.inf, None
    for shift in shift_range:
        M = np.clip(np.round(target * (2**shift)), 0, 255)
        actual = M / (2**shift)
        err = np.sum((actual - target)**2)
        if err < best_err:
            best_shift, best_err, best_M = shift, err, M
    return best_shift, best_M.astype(np.uint8)

l1_shift, l1_M = solve_quantize_params(w1_scale, INPUT_SCALE, l1_output_scale)
l2_shift, l2_M = solve_quantize_params(w2_scale, l1_output_scale, l2_output_scale)

# input: 784 -> 832 (13 K-tiles of 64), K-only padding, M/N already 64
W1_q_padded = np.zeros((64, 832), dtype=np.int8)
W1_q_padded[:, :784] = W1_q

# output: 10 -> 64. NOT the earlier "10->16" plan -- superseded when batch=64
# forced layer 3's tile to tiles=8 (64-cube) to cover N=batch=64, which also
# pads M (output classes) to 64, not 16. Zero rows are dead weight/bias, safe
# to ignore at host-side argmax.
W3_q_padded = np.zeros((64, 64), dtype=np.int8)
W3_q_padded[:10, :] = W3_q
b3_q_padded = np.zeros(64, dtype=np.int8)
b3_q_padded[:10] = b3_q

np.savez('mnist_quantized.npz',
    W1_q=W1_q_padded, b1_q=b1_q,
    W2_q=W2_q, b2_q=b2_q,
    W3_q=W3_q_padded, b3_q=b3_q_padded,
    l1_M=l1_M, l1_shift=l1_shift,
    l2_M=l2_M, l2_shift=l2_shift,
    input_scale=INPUT_SCALE,
    l1_output_scale=l1_output_scale,
    l2_output_scale=l2_output_scale,
)

print("L1 weight scale range:", w1_scale.min(), w1_scale.max())
print("L2 weight scale range:", w2_scale.min(), w2_scale.max())
print("L3 weight scale range:", w3_scale.min(), w3_scale.max())
print("L1 shift:", l1_shift, " L2 shift:", l2_shift)
print("Saved mnist_quantized.npz")