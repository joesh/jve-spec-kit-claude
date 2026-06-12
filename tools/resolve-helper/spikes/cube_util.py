"""Shared .cube helpers for the t05x probe spikes (t051/t052/t053).

Lifted at the third copy (t051, t052 carried identical inline
versions). Pure stdlib; data layout matches Resolve's .cube writer:
row-major with R fastest (index = (b*size + g)*size + r).
"""


# Non-data header keywords from the Adobe .cube spec. Resolve's stock
# LUTs carry LUT_3D_INPUT_RANGE (not just DOMAIN_MIN/MAX).
_HEADER_KEYWORDS = ("TITLE", "DOMAIN_MIN", "DOMAIN_MAX", "LUT_1D_SIZE",
                    "LUT_1D_INPUT_RANGE", "LUT_3D_INPUT_RANGE")


def load_cube(path):
    size, data = None, []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("LUT_3D_SIZE"):
                size = int(line.split()[1])
                continue
            if line[0].isalpha():
                if not line.startswith(_HEADER_KEYWORDS):
                    raise ValueError(
                        f"{path}: unknown .cube keyword in {line!r}")
                continue
            parts = line.split()
            if len(parts) != 3:
                raise ValueError(f"{path}: bad data line {line!r}")
            data.append(tuple(float(x) for x in parts))
    if not size or len(data) != size ** 3:
        raise ValueError(f"{path}: bad cube (size={size}, {len(data)} rows)")
    return size, data


def cubes_identical(path_a, path_b, tol=0.0005):
    size_a, data_a = load_cube(path_a)
    size_b, data_b = load_cube(path_b)
    if size_a != size_b:
        return False
    return all(abs(a - b) <= tol
               for ta, tb in zip(data_a, data_b)
               for a, b in zip(ta, tb))


def sample_gray(path, v):
    """Nearest-lattice gray-axis sample of an on-disk cube."""
    size, data = load_cube(path)
    i = round(v * (size - 1))
    return data[(i * size + i) * size + i]


def trilerp(size, data, r, g, b):
    """Trilinear sample of a loaded cube at (r, g, b) in [0, 1]."""
    def axis(v):
        v = min(max(v, 0.0), 1.0) * (size - 1)
        lo = min(int(v), size - 2)
        return lo, v - lo

    ri, rf = axis(r)
    gi, gf = axis(g)
    bi, bf = axis(b)

    def at(dr, dg, db):
        return data[((bi + db) * size + (gi + dg)) * size + (ri + dr)]

    out = []
    for ch in range(3):
        c00 = at(0, 0, 0)[ch] * (1 - rf) + at(1, 0, 0)[ch] * rf
        c10 = at(0, 1, 0)[ch] * (1 - rf) + at(1, 1, 0)[ch] * rf
        c01 = at(0, 0, 1)[ch] * (1 - rf) + at(1, 0, 1)[ch] * rf
        c11 = at(0, 1, 1)[ch] * (1 - rf) + at(1, 1, 1)[ch] * rf
        c0 = c00 * (1 - gf) + c10 * gf
        c1 = c01 * (1 - gf) + c11 * gf
        out.append(c0 * (1 - bf) + c1 * bf)
    return tuple(out)
