// Iris matcher over binary iris codes (Daugman-style): normalised Hamming
// distance over bits valid in both masks, minimised over small rotations.
//
// SIMPLIFICATIONS (replace with a certified engine before real use):
//  - rotation is a circular shift of the whole bit string, not per-row
//  - codes/masks here come from synthetic test data, not a real iris encoder
//  - thresholds are placeholders and must be tuned on real genuine/impostor data

function toBits(buf) {
  const bits = new Uint8Array(buf.length * 8);
  for (let i = 0; i < buf.length; i++) {
    for (let b = 0; b < 8; b++) {
      bits[i * 8 + b] = (buf[i] >> (7 - b)) & 1;
    }
  }
  return bits;
}

function hammingAtShift(a, b, maskA, maskB, shift) {
  const n = a.length;
  let diff = 0;
  let valid = 0;
  for (let i = 0; i < n; i++) {
    const j = (i + shift + n) % n;
    if (maskA[i] && maskB[j]) {
      valid++;
      if (a[i] !== b[j]) diff++;
    }
  }
  return valid === 0 ? 1 : diff / valid;
}

export function irisDistance(codeA, codeB, { maskA, maskB, maxShift = 8 } = {}) {
  if (codeA.length !== codeB.length) {
    throw new Error("Iris codes must have equal length");
  }
  const a = toBits(codeA);
  const b = toBits(codeB);
  const mA = maskA ? toBits(maskA) : new Uint8Array(a.length).fill(1);
  const mB = maskB ? toBits(maskB) : new Uint8Array(b.length).fill(1);
  let best = 1;
  for (let s = -maxShift; s <= maxShift; s++) {
    best = Math.min(best, hammingAtShift(a, b, mA, mB, s));
  }
  return best;
}

// Map distance to the 0-100 scale used by identity.match_cases.match_score.
// HD ~0.5 (unrelated irises) -> 0; HD 0 (identical) -> 100.
export function irisScore(codeA, codeB, options) {
  const hd = irisDistance(codeA, codeB, options);
  const score = ((0.5 - hd) / 0.5) * 100;
  return Math.max(0, Math.min(100, Math.round(score * 100) / 100));
}
