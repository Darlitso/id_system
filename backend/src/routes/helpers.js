import { HttpError } from "../db/api.js";

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const ID_NUMBER_RE = /^\d{6}\/\d{2}\/\d$/;

export const ctx = (req) => ({ requestId: req.id, ip: req.ip ?? null });

export function uuidParam(value, name = "id") {
  if (typeof value !== "string" || !UUID_RE.test(value)) {
    throw new HttpError(400, "invalid_request", `${name} must be a valid id`);
  }
  return value;
}

export function text(value, name, { required = false, max = 160 } = {}) {
  if (value === undefined || value === null || value === "") {
    if (required) throw new HttpError(400, "invalid_request", `${name} is required`);
    return null;
  }
  if (typeof value !== "string" || value.length > max) {
    throw new HttpError(400, "invalid_request", `${name} must be text of at most ${max} characters`);
  }
  return value.trim();
}

export function isoDate(value, name) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(value))) {
    throw new HttpError(400, "invalid_request", `${name} must be a date (YYYY-MM-DD)`);
  }
  return value;
}

export function oneOf(value, name, allowed, { optional = false } = {}) {
  if ((value === undefined || value === null || value === "") && optional) return null;
  if (!allowed.includes(value)) {
    throw new HttpError(400, "invalid_request", `${name} must be one of: ${allowed.join(", ")}`);
  }
  return value;
}
