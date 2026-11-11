// The backend talks to the database ONLY through the identity.api_* functions
// (migrations 004 and 005). Function names are constants, never user input.
const FUNCTIONS = new Set([
  "api_get_staff_login", "api_record_login", "api_get_enrolment", "api_list_enrolments",
  "api_list_citizens", "api_list_match_cases", "api_list_audit", "api_stats",
  "api_submit_enrolment", "api_store_template", "api_get_gallery", "api_record_match_case",
  "api_review_match", "api_decide_enrolment", "api_write_audit", "api_verify_lookup",
  "api_record_verification",
]);

export async function callApi(db, fn, params = []) {
  if (!FUNCTIONS.has(fn)) throw new Error(`Unknown API function ${fn}`);
  const placeholders = params.map((_, i) => `$${i + 1}`).join(", ");
  const { rows } = await db.query(`SELECT * FROM identity.${fn}(${placeholders})`, params);
  return rows;
}

// Scalar-returning functions come back as { <function name>: value }.
export async function callScalar(db, fn, params = []) {
  const rows = await callApi(db, fn, params);
  return rows[0]?.[fn];
}

export class HttpError extends Error {
  constructor(status, code, message) {
    super(message ?? code);
    this.status = status;
    this.code = code;
  }
}

const BY_STATE = {
  "42501": [403, "forbidden", "You are not permitted to do this"],
  "22023": [400, "invalid_request"],
  "23503": [404, "not_found", "Record not found"],
  "55000": [409, "conflict"],
  "23514": [400, "invalid_request", "Invalid value"],
  "23505": [409, "conflict", "Already exists"],
};

// Our own functions raise readable messages; anything else gets a generic one.
export function toHttpError(error) {
  if (error instanceof HttpError) return error;
  const mapped = BY_STATE[error?.code];
  if (!mapped) return null;
  const [status, code, fixed] = mapped;
  const ours = typeof error.where === "string" && error.where.includes("identity.api_");
  const message = fixed ?? (ours ? error.message : "Request rejected");
  return new HttpError(status, code, message);
}
