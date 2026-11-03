const http = require('http');
const fs = require('fs');
const path = require('path');

let seq = 100004;
let nextId = 5;
const citizens = [
  { id: 1, identity_number: '100001/10/1', full_name: 'Mwansa Chileshe', date_of_birth: '1990-03-14', district: 'Lusaka', status: 'active' },
  { id: 2, identity_number: '100002/10/1', full_name: 'Natasha Banda', date_of_birth: '1995-07-22', district: 'Kitwe', status: 'active' },
  { id: 3, identity_number: '100003/10/1', full_name: 'Joseph Phiri', date_of_birth: '1982-11-05', district: 'Livingstone', status: 'active' },
  { id: 4, identity_number: null, full_name: 'Grace Mulenga', date_of_birth: '2000-01-30', district: 'Lusaka', status: 'pending' },
];

function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'Content-Type': type });
  res.end(type === 'application/json' ? JSON.stringify(body) : body);
}
function readBody(req) {
  return new Promise(resolve => {
    let d = '';
    req.on('data', c => (d += c));
    req.on('end', () => { try { resolve(JSON.parse(d || '{}')); } catch { resolve({}); } });
  });
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  if (req.method === 'GET' && p === '/') {
    const page = fs.readFileSync(path.join(__dirname, '..', 'frontend', 'index.html'), 'utf8');
    return send(res, 200, page, 'text/html; charset=utf-8');
  }
  if (req.method === 'GET' && p === '/api/citizens') return send(res, 200, citizens);

  if (req.method === 'POST' && p === '/api/citizens') {
    const b = await readBody(req);
    if (!b.full_name || !b.date_of_birth) return send(res, 400, { error: 'Name and date of birth are required' });
    const c = { id: nextId++, identity_number: null, full_name: String(b.full_name), date_of_birth: String(b.date_of_birth), district: String(b.district || ''), status: 'pending' };
    citizens.push(c);
    return send(res, 201, c);
  }

  const m = p.match(/^\/api\/citizens\/(\d+)\/(approve|reject)$/);
  if (req.method === 'POST' && m) {
    const c = citizens.find(x => x.id === Number(m[1]));
    if (!c) return send(res, 404, { error: 'Not found' });
    if (c.status !== 'pending') return send(res, 400, { error: 'Only pending applications can be decided' });
    if (m[2] === 'approve') { c.status = 'active'; c.identity_number = `${++seq}/10/1`; }
    else c.status = 'rejected';
    return send(res, 200, c);
  }

  if (req.method === 'GET' && p === '/api/verify') {
    const c = citizens.find(x => x.identity_number === url.searchParams.get('number'));
    if (!c) return send(res, 200, { result: 'not_verified' });
    if (c.status !== 'active') return send(res, 200, { result: 'revoked' });
    return send(res, 200, { result: 'verified', full_name: c.full_name });
  }

  send(res, 404, { error: 'Not found' });
}).listen(3000, () => console.log('Running at http://localhost:3000'));