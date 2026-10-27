"""Ball vision prototype package.

All core operations are integer/fixed-point so the Python reference can be
ported to RTL bit-exactly.  OpenCV is used only for decoding/encoding and for
rectangular morphology (min/max), whose integer semantics are exact.
"""

__version__ = "0.1.0"
