"""Numba-jitted port of mapbox/pixelmatch for kintsuki framebuffer
pixel-diff oracles. Keeps the runtime dep on numpy/numba/Pillow inside
the dev group; production kintsuki users don't pull these in.

Algorithm reference: https://github.com/mapbox/pixelmatch
"""

import math

import numpy as np
from numpy.typing import NDArray
from PIL import Image

# Attempt to import Numba, required for performance
try:
    import numba
except ImportError as e:
    print("Numba not found. Please install Numba for performance: pip install numba")
    # Fallback or error out if Numba is critical
    raise SystemExit("Numba is required for this optimized version of pixelmatch.") from e


# Type alias for color tuples
ColorTuple = tuple[int, int, int]
OptionalColorTuple = ColorTuple | None

# Constants used in _color_delta
_PHI: float = 1.618033988749895
_PHI_SQ: float = 2.618033988749895  # Or math.pow(_PHI, 2)

# Helper Functions with Numba JIT compilation


@numba.njit(cache=True)  # (cache=True) can speed up subsequent script runs
def _draw_pixel_numba(output_arr: NDArray[np.uint8], pos: int, r: int, g: int, b: int) -> None:
    """Draws a pixel into the output array (Numba JITted)."""
    output_arr[pos + 0] = r
    output_arr[pos + 1] = g
    output_arr[pos + 2] = b
    output_arr[pos + 3] = 255  # Opaque


@numba.njit(cache=True)
def _draw_gray_pixel_numba(
    img_data: NDArray[np.uint8], i: int, alpha_param: float, output_arr: NDArray[np.uint8]
) -> None:
    """Draws a grayscale pixel, blended with white, into the output array (Numba JITted)."""
    r_val, g_val, b_val, a_val = img_data[i], img_data[i + 1], img_data[i + 2], img_data[i + 3]

    gray: float = float(r_val) * 0.29889531 + float(g_val) * 0.58662247 + float(b_val) * 0.11448223

    effective_alpha: float = alpha_param * (float(a_val) / 255.0)
    val_float: float = 255.0 + (gray - 255.0) * effective_alpha

    val_int: int = max(0, min(255, int(val_float)))  # Truncation towards zero via int(), then clamp
    _draw_pixel_numba(output_arr, i, val_int, val_int, val_int)


@numba.njit(cache=True)
def _fill_gray_pixels_numba(
    img_data: NDArray[np.uint8], alpha_param: float, output_data: NDArray[np.uint8], num_pixels: int
) -> None:
    """Fills the output_data with grayscale versions of img_data pixels (Numba JITted)."""
    for i in range(num_pixels):
        _draw_gray_pixel_numba(img_data, i * 4, alpha_param, output_data)


@numba.njit(cache=True)
def _color_delta_numba(
    img1_data: NDArray[np.uint8], img2_data: NDArray[np.uint8], k: int, m: int, y_only: bool
) -> float:
    """Calculates color difference (Numba JITted)."""
    r1, g1, b1, a1 = float(img1_data[k]), float(img1_data[k + 1]), float(img1_data[k + 2]), float(img1_data[k + 3])
    r2, g2, b2, a2 = float(img2_data[m]), float(img2_data[m + 1]), float(img2_data[m + 2]), float(img2_data[m + 3])

    dr: float = r1 - r2
    dg: float = g1 - g2
    db: float = b1 - b2
    da: float = a1 - a2

    if dr == 0 and dg == 0 and db == 0 and da == 0:
        return 0.0

    if a1 < 255.0 or a2 < 255.0:
        rb_factor: int = k % 2
        gb_factor: int = math.trunc(k / _PHI) % 2  # math.trunc is supported by Numba
        bb_factor: int = math.trunc(k / _PHI_SQ) % 2

        bg_r: float = 48.0 + 159.0 * rb_factor
        bg_g: float = 48.0 + 159.0 * gb_factor
        bg_b: float = 48.0 + 159.0 * bb_factor

        dr = (r1 * a1 - r2 * a2 - bg_r * da) / 255.0
        dg = (g1 * a1 - g2 * a2 - bg_g * da) / 255.0
        db = (b1 * a1 - b2 * a2 - bg_b * da) / 255.0

    y: float = dr * 0.29889531 + dg * 0.58662247 + db * 0.11448223
    if y_only:
        return y

    i_comp: float = dr * 0.59597799 - dg * 0.27417610 - db * 0.32180189
    q_comp: float = dr * 0.21147017 - dg * 0.52261711 + db * 0.31114694

    delta_sq: float = 0.5053 * y * y + 0.299 * i_comp * i_comp + 0.1957 * q_comp * q_comp

    return -delta_sq if y > 0 else delta_sq


@numba.njit(cache=True)
def _has_many_siblings_numba(img_uint32: NDArray[np.uint32], x1: int, y1: int, width: int, height: int) -> bool:
    """Checks for siblings (Numba JITted)."""
    x0: int = max(x1 - 1, 0)
    y0: int = max(y1 - 1, 0)
    x2: int = min(x1 + 1, width - 1)
    y2: int = min(y1 + 1, height - 1)

    center_idx: int = y1 * width + x1
    center_val: np.uint32 = img_uint32[center_idx]

    zeroes: int = 1 if (x1 == x0 or x1 == x2 or y1 == y0 or y1 == y2) else 0

    for x_coord in range(x0, x2 + 1):
        for y_coord in range(y0, y2 + 1):
            if x_coord == x1 and y_coord == y1:
                continue

            neighbor_idx: int = y_coord * width + x_coord
            if center_val == img_uint32[neighbor_idx]:
                zeroes += 1

            if zeroes > 2:
                return True
    return False


@numba.njit(cache=True)
def _antialiased_numba(
    img_data_uint8: NDArray[np.uint8],
    x1: int,
    y1: int,
    width: int,
    height: int,
    img_a32: NDArray[np.uint32],
    img_b32: NDArray[np.uint32],
) -> bool:
    """Anti-aliasing detection (Numba JITted)."""
    x0: int = max(x1 - 1, 0)
    y0: int = max(y1 - 1, 0)
    x2: int = min(x1 + 1, width - 1)
    y2: int = min(y1 + 1, height - 1)

    center_pixel_flat_idx: int = y1 * width + x1
    center_pixel_byte_idx: int = center_pixel_flat_idx * 4

    zeroes: int = 1 if (x1 == x0 or x1 == x2 or y1 == y0 or y1 == y2) else 0

    min_y_delta: float = 0.0
    max_y_delta: float = 0.0
    # Numba requires variables to be assigned before use in all branches,
    # initialize min_x, min_y etc. properly.
    min_x, min_y, max_x, max_y = 0, 0, 0, 0

    for x_coord in range(x0, x2 + 1):
        for y_coord in range(y0, y2 + 1):
            if x_coord == x1 and y_coord == y1:
                continue

            neighbor_pixel_flat_idx: int = y_coord * width + x_coord
            neighbor_pixel_byte_idx: int = neighbor_pixel_flat_idx * 4

            delta: float = _color_delta_numba(
                img_data_uint8, img_data_uint8, center_pixel_byte_idx, neighbor_pixel_byte_idx, y_only=True
            )

            if delta == 0:
                zeroes += 1
                if zeroes > 2:
                    return False
            elif delta < min_y_delta:
                min_y_delta = delta
                min_x, min_y = x_coord, y_coord
            elif delta > max_y_delta:
                max_y_delta = delta
                max_x, max_y = x_coord, y_coord

    if min_y_delta == 0 or max_y_delta == 0:
        return False

    if _has_many_siblings_numba(img_a32, min_x, min_y, width, height) and _has_many_siblings_numba(
        img_b32, min_x, min_y, width, height
    ):
        return True

    if _has_many_siblings_numba(img_a32, max_x, max_y, width, height) and _has_many_siblings_numba(
        img_b32, max_x, max_y, width, height
    ):
        return True

    return False


@numba.njit(cache=True)
def _process_pixels_numba(
    img1_data: NDArray[np.uint8],
    img2_data: NDArray[np.uint8],
    img1_u32: NDArray[np.uint32],
    img2_u32: NDArray[np.uint32],
    output_data: NDArray[np.uint8],
    width: int,
    height: int,
    threshold: float,
    include_aa: bool,
    alpha: float,
    aa_color: ColorTuple,
    diff_color: ColorTuple,
    effective_diff_color_alt: ColorTuple,
    diff_mask: bool,
    max_sq_delta: float,
) -> int:
    """Core pixel processing loop (Numba JITted)."""
    mismatch_count: int = 0
    aa_r, aa_g, aa_b = aa_color
    diff_r, diff_g, diff_b = diff_color
    alt_r, alt_g, alt_b = effective_diff_color_alt

    for y_coord in range(height):
        for x_coord in range(width):
            pixel_idx: int = y_coord * width + x_coord
            pos: int = pixel_idx * 4

            delta: float = 0.0
            if img1_u32[pixel_idx] != img2_u32[pixel_idx]:
                delta = _color_delta_numba(img1_data, img2_data, pos, pos, y_only=False)

            # Numba needs `abs` for floats, ensure it's `math.fabs` or Python's `abs` which Numba handles.
            if abs(delta) > max_sq_delta:
                is_aa: bool = _antialiased_numba(
                    img1_data, x_coord, y_coord, width, height, img1_u32, img2_u32
                ) or _antialiased_numba(img2_data, x_coord, y_coord, width, height, img2_u32, img1_u32)

                if not include_aa and is_aa:
                    if not diff_mask:
                        _draw_pixel_numba(output_data, pos, aa_r, aa_g, aa_b)
                else:
                    if delta < 0:
                        _draw_pixel_numba(output_data, pos, alt_r, alt_g, alt_b)
                    else:
                        _draw_pixel_numba(output_data, pos, diff_r, diff_g, diff_b)
                    mismatch_count += 1
            elif not diff_mask:
                _draw_gray_pixel_numba(img1_data, pos, alpha, output_data)
    return mismatch_count


def pixelmatch(
    img1_pil: Image.Image,
    img2_pil: Image.Image,
    *,
    threshold: float = 0.1,
    include_aa: bool = False,
    alpha: float = 0.1,
    aa_color: ColorTuple = (255, 255, 0),
    diff_color: ColorTuple = (255, 0, 0),
    diff_color_alt: OptionalColorTuple = None,
    diff_mask: bool = False,
) -> tuple[int, Image.Image]:
    """
    Compares two PIL Images pixel by pixel using Numba-optimized routines.
    Returns a tuple: (number_of_mismatched_pixels, diff_image_as_PIL_Image).
    """

    if img1_pil.mode != "RGBA":
        img1_pil = img1_pil.convert("RGBA")
    if img2_pil.mode != "RGBA":
        img2_pil = img2_pil.convert("RGBA")

    if img1_pil.size != img2_pil.size:
        raise ValueError("Image sizes do not match.")

    width: int = img1_pil.width
    height: int = img1_pil.height

    if width == 0 or height == 0:
        return 0, Image.new("RGBA", (0, 0))

    img1_data: NDArray[np.uint8] = np.array(img1_pil, dtype=np.uint8).ravel()
    img2_data: NDArray[np.uint8] = np.array(img2_pil, dtype=np.uint8).ravel()

    output_data: NDArray[np.uint8] = np.zeros(width * height * 4, dtype=np.uint8)

    if diff_color_alt is None:
        effective_diff_color_alt: ColorTuple = diff_color
    else:
        effective_diff_color_alt: ColorTuple = diff_color_alt

    num_pixels: int = width * height

    img1_u32: NDArray[np.uint32] = img1_data.view(np.uint32)
    img2_u32: NDArray[np.uint32] = img2_data.view(np.uint32)

    if np.array_equal(img1_u32, img2_u32):  # This NumPy check is fast
        if not diff_mask:
            # Use Numba JITted function for filling gray pixels
            _fill_gray_pixels_numba(img1_data, alpha, output_data, num_pixels)
        diff_img_pil = Image.fromarray(output_data.reshape((height, width, 4)), "RGBA")
        return 0, diff_img_pil

    max_sq_delta: float = 35215.0 * threshold * threshold

    mismatch_count = _process_pixels_numba(
        img1_data,
        img2_data,
        img1_u32,
        img2_u32,
        output_data,
        width,
        height,
        threshold,
        include_aa,
        alpha,
        aa_color,
        diff_color,
        effective_diff_color_alt,
        diff_mask,
        max_sq_delta,
    )

    diff_img_pil = Image.fromarray(output_data.reshape((height, width, 4)), "RGBA")
    return mismatch_count, diff_img_pil
