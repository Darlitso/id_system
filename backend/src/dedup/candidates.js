/**
 * Pure candidate search: compare one probe template against a gallery and
 * return the candidates scoring at or above `reviewScore`, best first.
 *
 * - Never decides that someone IS a duplicate. Output is only a list of
 *   candidates that must go to human review (identity.match_cases).
 * - `matcher` is pluggable: (probeTemplate, galleryTemplate) => score 0-100.
 * - Gallery entries for the probe's own citizen are skipped.
 */
export function findCandidates({
  probe, // { citizenId, modality, template }
  gallery, // iterable of { citizenId, modality, template }
  matcher,
  reviewScore,
}) {
  const bestByCitizen = new Map();

  for (const entry of gallery) {
    if (entry.citizenId === probe.citizenId) continue;
    if (entry.modality !== probe.modality) continue;
    const score = matcher(probe.template, entry.template);
    if (score < reviewScore) continue;
    const current = bestByCitizen.get(entry.citizenId);
    if (current === undefined || score > current) {
      bestByCitizen.set(entry.citizenId, score);
    }
  }

  return [...bestByCitizen.entries()]
    .map(([candidateCitizenId, matchScore]) => ({
      candidateCitizenId,
      modality: probe.modality,
      matchScore,
    }))
    .sort((a, b) => b.matchScore - a.matchScore);
}
