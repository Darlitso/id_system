import { irisScore } from "./irisMatcher.js";

// One matcher per modality, all returning a 0-100 score.
// PLACEHOLDERS until a certified engine is integrated:
//  - iris: Hamming distance over equal-length codes (see irisMatcher.js)
//  - fingerprint: the same bit comparison without rotation. Real fingerprint matching
//    compares minutiae and needs a vendor SDK; this only stands in so the pipeline runs.
export function matcherFor(modality) {
  const raw =
    modality === "iris"
      ? (a, b) => irisScore(a, b)
      : modality === "fingerprint"
        ? (a, b) => irisScore(a, b, { maxShift: 0 })
        : null;
  if (!raw) throw new Error(`No matcher for modality "${modality}"`);
  // A malformed or different-sized template must never crash a search; it just scores 0.
  return (a, b) => {
    try {
      return raw(a, b);
    } catch {
      return 0;
    }
  };
}
