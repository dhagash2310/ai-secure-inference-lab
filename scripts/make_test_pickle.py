"""Create a harmless 'malicious-looking' pickle to prove the scan gate fails closed.

Loading this file runs `echo scan-gate-test`. It does nothing else. Never unpickle it yourself;
the point is that a scanner should flag it without loading it.
"""
import os
import pickle
import sys


class Payload:
    def __reduce__(self):
        return (os.system, ("echo scan-gate-test",))


out = sys.argv[1] if len(sys.argv) > 1 else "evil-test.pkl"
with open(out, "wb") as f:
    pickle.dump(Payload(), f)
print(f"wrote {out}")
