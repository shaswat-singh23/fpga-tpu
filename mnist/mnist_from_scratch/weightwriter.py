import numpy as np
from sklearn.datasets import fetch_openml
from golden_model import pixels_to_int8 

q = np.load('mnist_quantized.npz')

def emit_array(f, name, arr, ctype):
    flat = arr.flatten()
    f.write(f"static const {ctype} {name}[{flat.size}] = {{\n    ")
    f.write(", ".join(str(int(v)) for v in flat))
    f.write("\n};\n\n")

with open('weights_data.h', 'w') as f:
    f.write("#ifndef WEIGHTS_DATA_H\n#define WEIGHTS_DATA_H\n\n")
    emit_array(f, "W1_DATA", q['W1_q'], "s8")   # (64, 832) row-major
    emit_array(f, "B1_DATA", q['b1_q'], "s8")
    emit_array(f, "W2_DATA", q['W2_q'], "s8")   # (64, 64)
    emit_array(f, "B2_DATA", q['b2_q'], "s8")
    emit_array(f, "W3_DATA", q['W3_q'], "s8")   # (64, 64), padded
    emit_array(f, "B3_DATA", q['b3_q'], "s8")
    emit_array(f, "L1_M_DATA", q['l1_M'], "u8")
    emit_array(f, "L2_M_DATA", q['l2_M'], "u8")
    f.write(f"#define L1_SHIFT {int(q['l1_shift'])}\n")
    f.write(f"#define L2_SHIFT {int(q['l2_shift'])}\n")
    f.write("\n#endif\n")

print("wrote weights_data.h")


  # reuses the exact same conversion golden_model.py uses

mnist = fetch_openml('mnist_784', version=1, as_frame=False, parser='liac-arff')
X, y = mnist.data, mnist.target.astype(int)

np.random.seed(67)
perm = np.random.permutation(X.shape[0])
X_shuf, y_shuf = X[perm], y[perm]

X_batch_int8 = pixels_to_int8((X_shuf[:64].T) / 255.)
Y_batch = y_shuf[:64]

def emit_array(f, name, arr, ctype):
    flat = arr.flatten()
    f.write(f"static const {ctype} {name}[{flat.size}] = {{\n    ")
    f.write(", ".join(str(int(v)) for v in flat))
    f.write("\n};\n\n")

with open('test_data.h', 'w') as f:
    f.write("#ifndef TEST_DATA_H\n#define TEST_DATA_H\n\n")
    emit_array(f, "X_INPUT", X_batch_int8, "s8")
    emit_array(f, "Y_LABELS", Y_batch, "u8")
    f.write("\n#endif\n")

