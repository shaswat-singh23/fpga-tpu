from matplotlib import pyplot as plt
from sklearn.datasets import fetch_openml
import numpy as np

mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='liac-arff')
X, y = mnist.data, mnist.target.astype(int)
X_full = X.T

m = X_full.shape[1]

np.random.seed(67)   # MUST match train.py exactly, or dev set won't be the same held-out examples
perm = np.random.permutation(m)
X_full = X_full[:, perm]
y_full = y[perm]

X_dev = X_full[:, 0:1000] / 255.
Y_dev = y_full[0:1000]

X_train = X_full[:, 1000:m] / 255.
Y_train = y_full[1000:m]


weights = np.load('mnist_weights.npz')
W1, b1, W2, b2, W3, b3 = weights['W1'], weights['b1'], weights['W2'], weights['b2'], weights['W3'], weights['b3']

# ReLU, softmax, forward_prop, get_predictions, get_accuracy, make_predictions,
input_scale = 1.0 / 127.0

for name, W, b in [('L1', W1, b1), ('L2', W2, b2), ('L3', W3, b3)]:
    weight_scale = np.max(np.abs(W), axis=1) / 127.0  # per-neuron, shape matches b
    bias_scale = weight_scale * input_scale  # what layer 1 needs; layers 2/3 need each stage's actual input_scale which comes from the previous QUANTIZE's output
    bias_int8 = np.round(b.flatten() / bias_scale)
    clipped = np.sum(np.abs(bias_int8) > 127)
    max_needed = np.max(np.abs(bias_int8))
    print(f"{name}: {clipped}/{len(bias_int8)} bias entries would clip, max magnitude needed: {max_needed:.1f}")

def ReLU(Z):
    return np.maximum(Z, 0)

def softmax(Z):
    expZ = np.exp(Z - np.max(Z, axis=0, keepdims=True))
    A = expZ / np.sum(expZ, axis=0, keepdims=True)
    return A


def forward_prop(W1, b1, W2, b2, W3, b3, X):
    Z1 = W1.dot(X) + b1
    A1 = ReLU(Z1)
    Z2 = W2.dot(A1) + b2
    A2 = ReLU(Z2)
    Z3 = W3.dot(A2) + b3
    A3 = softmax(Z3)
    return Z1, A1, Z2, A2, Z3, A3


def get_predictions(A3):
    return np.argmax(A3, 0)

def get_accuracy(predictions, Y):
    print(predictions, Y)
    return np.sum(predictions == Y) / Y.size


def make_predictions(X, W1, b1, W2, b2, W3, b3):
    _, _, _, _, _, A3 = forward_prop(W1, b1, W2, b2, W3, b3, X)
    predictions = get_predictions(A3)
    return predictions

def test_prediction(index, W1, b1, W2, b2, W3, b3):
    current_image = X_train[:, index, None]
    prediction = make_predictions(X_train[:, index, None], W1, b1, W2, b2, W3, b3)
    label = Y_train[index]
    print("Prediction: ", prediction)
    print("Label: ", label)
    
    current_image = current_image.reshape((28, 28)) * 255
    plt.gray()
    plt.imshow(current_image, interpolation='nearest')
    plt.show()

dev_predictions = make_predictions(X_dev, W1, b1, W2, b2, W3, b3)
print(get_accuracy(dev_predictions, Y_dev))