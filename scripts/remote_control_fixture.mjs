// Local, synthetic Jellyfin subset for remote-control browser acceptance.
// Importing this module never binds a listener or opens a browser.
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { EventEmitter } from 'node:events';

export const fixtureConstants = Object.freeze({
  serverId: 'remote-fixture-server', userId: 'remote-fixture-user',
  foreignUserId: 'foreign-fixture-user', itemId: 'remote-fixture-item',
  playSessionId: 'fixture-play-1', playbackId: 'jms-remote-fixture-play-1',
  sourceA: 'source-a', sourceB: 'source-b', durationTicks: 300000000,
  receiver: Object.freeze({ token: 'receiver-fixture-token', deviceId: 'receiver-fixture-device',
    sessionId: 'receiver-fixture-session', client: 'JMS', deviceName: 'Tesla fixture' }),
  controller: Object.freeze({ token: 'phone-fixture-token', deviceId: 'phone-fixture-device',
    sessionId: 'phone-fixture-session', client: 'JMS', deviceName: 'Phone fixture' }),
  foreign: Object.freeze({ token: 'foreign-fixture-token', deviceId: 'foreign-fixture-device',
    sessionId: 'foreign-fixture-session', client: 'JMS', deviceName: 'Foreign account fixture' }),
});

const C = fixtureConstants;
const commandTypes = ['PlayState', 'SetSubtitleStreamIndex'];
const metadataKeys = ['JmsRemoteVersion', 'JmsTargetSessionId', 'JmsItemId',
  'JmsMediaSourceId', 'JmsPlaybackId', 'JmsControllerId', 'JmsRequestId',
  'JmsSequence', 'JmsIssuedAt', 'JmsExpiresAt'];
const clone = value => structuredClone(value);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const mime = name => ({ '.html': 'text/html; charset=utf-8', '.js': 'application/javascript',
  '.mjs': 'application/javascript', '.json': 'application/json', '.wasm': 'application/wasm',
  '.css': 'text/css', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf',
  '.otf': 'font/otf', '.woff2': 'font/woff2', '.mp4': 'video/mp4', '.vtt': 'text/vtt; charset=utf-8' }[path.extname(name)] || 'application/octet-stream');

function identityFor(token) {
  for (const [role, identity] of Object.entries({ receiver: C.receiver, controller: C.controller, foreign: C.foreign })) {
    if (token === identity.token) return { ...identity, role,
      userId: role === 'foreign' ? C.foreignUserId : C.userId };
  }
  return null;
}

function authenticated(req) {
  const header = String(req.headers.authorization || req.headers['x-emby-authorization'] || '');
  const token = String(req.headers['x-emby-token'] || /(?:^|[ ,])Token="([^"]+)"/i.exec(header)?.[1] || '');
  const identity = identityFor(token);
  if (!identity) return null;
  const deviceId = /(?:^|[ ,])DeviceId="([^"]+)"/i.exec(header)?.[1] || req.headers['x-emby-device-id'];
  const client = /(?:^|[ ,])Client="([^"]+)"/i.exec(header)?.[1];
  if (deviceId !== identity.deviceId || (client && client !== identity.client)) return null;
  return identity;
}

function hasSubtitleMetadataFields(url) {
  // The generated client repeats list-valued query keys. Jellyfin's list
  // binder accepts a single comma-delimited value or repeated scalar values.
  const values = url.searchParams.getAll('fields');
  const fields = (values.length === 1 ? values[0].split(',') : values).map(value => value.trim());
  return fields.length === 2 && new Set(fields).size === 2 &&
    fields.includes('MediaSources') && fields.includes('MediaStreams');
}

function validCommand(command) {
  if (!command || typeof command !== 'object' || !commandTypes.includes(command.Name)) return false;
  const args = command.Arguments;
  if (!args || Array.isArray(args) || typeof args !== 'object' ||
      Object.entries(args).some(([key, value]) => typeof key !== 'string' || typeof value !== 'string' || value.length > 4096)) return false;
  let extras;
  if (command.Name === 'SetSubtitleStreamIndex') {
    if (!/^(?:-1|0|[1-9][0-9]*)$/.test(args.Index || '')) return false;
    extras = ['Index'];
  } else if (args.Command === 'Seek') {
    if (!/^(?:0|[1-9][0-9]*)$/.test(args.SeekPositionTicks || '') || !Number.isSafeInteger(Number(args.SeekPositionTicks))) return false;
    extras = ['Command', 'SeekPositionTicks'];
  } else {
    if (!['Pause', 'Unpause'].includes(args.Command)) return false;
    extras = ['Command'];
  }
  const keys = [...metadataKeys, ...extras].sort();
  return args.JmsRemoteVersion === '1' &&
    keys.length === Object.keys(args).length && keys.every((key, i) => key === Object.keys(args).sort()[i]) &&
    metadataKeys.every(key => args[key].length > 0) &&
    /^[1-9][0-9]*$/.test(args.JmsSequence) && Number.isSafeInteger(Number(args.JmsSequence));
}

// RFC 6455: bounded unfragmented browser client frames; no extensions negotiated.
function encodeFrame(payload, opcode = 1) {
  const bytes = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  assert.ok(bytes.length <= 32768, 'Fixture WebSocket message limit');
  const header = Buffer.alloc(bytes.length < 126 ? 2 : 4);
  header[0] = 0x80 | opcode;
  if (bytes.length < 126) header[1] = bytes.length;
  else { header[1] = 126; header.writeUInt16BE(bytes.length, 2); }
  return Buffer.concat([header, bytes]);
}

export function decodeClientFrames(input) {
  const messages = [];
  let offset = 0;
  while (input.length - offset >= 2) {
    const first = input[offset], second = input[offset + 1];
    assert.equal(first & 0x70, 0, 'Unexpected WebSocket extension');
    assert.ok(first & 0x80, 'Fragmented messages are outside fixture subset');
    assert.ok(second & 0x80, 'Client frames must be masked');
    const opcode = first & 15;
    assert.ok([1, 8, 9, 10].includes(opcode), 'Unexpected WebSocket opcode');
    let length = second & 127, header = 2;
    if (length === 127) throw new Error('Oversize WebSocket frame');
    if (length === 126) {
      if (input.length - offset < 4) break;
      length = input.readUInt16BE(offset + 2); header = 4;
      assert.ok(length >= 126, 'Noncanonical WebSocket length');
    }
    assert.ok(length <= 32768 && (opcode === 1 || length <= 125), 'WebSocket size limit');
    if (input.length - offset < header + 4 + length) break;
    const mask = input.subarray(offset + header, offset + header + 4);
    const payload = Buffer.from(input.subarray(offset + header + 4, offset + header + 4 + length));
    for (let index = 0; index < length; index++) payload[index] ^= mask[index % 4];
    messages.push({ opcode, payload });
    offset += header + 4 + length;
  }
  return { messages, remainder: input.subarray(offset) };
}

function subtitleStream(source, index, title) {
  return { Type: 'Subtitle', Index: index, Codec: 'vtt', Language: 'eng',
    IsExternal: true, IsTextSubtitleStream: true, SupportsExternalStream: true,
    DisplayTitle: title, Title: title, DeliveryMethod: 'External',
    DeliveryUrl: `/fixture/subtitles/${source}/${index}.vtt` };
}

function itemMetadata(durationTicks) {
  const sources = [
    { Id: C.sourceA, Name: 'Source A', MediaStreams: [
      subtitleStream(C.sourceA, 3, 'Source A subtitles'), subtitleStream(C.sourceA, 7, 'Subtitle B') ] },
    { Id: C.sourceB, Name: 'Source B', MediaStreams: [
      subtitleStream(C.sourceB, 3, 'Wrong source subtitles') ] },
  ].map(source => ({ ...source, Protocol: 'Http', Container: 'mp4',
    Path: '/fixture/media.mp4', SupportsDirectPlay: true, SupportsDirectStream: true,
    RunTimeTicks: durationTicks }));
  return { Id: C.itemId, Name: 'Original loopback remote-control clip', Type: 'Movie',
    MediaType: 'Video', RunTimeTicks: durationTicks, MediaSources: sources,
    // This trap must never supply subtitles for Source A.
    MediaStreams: [subtitleStream(C.sourceB, 3, 'Wrong item-level subtitles')] };
}

export function createRemoteControlFixture({ bundleDir, mediaPath, host = '127.0.0.1', port = 0,
  durationTicks = C.durationTicks } = {}) {
  assert.equal(host, '127.0.0.1', 'Fixture binds only IPv4 loopback');
  assert.ok(Number.isInteger(port) && port >= 0 && port <= 65535);
  assert.ok(Number.isSafeInteger(durationTicks) && durationTicks > 0);
  const bundle = bundleDir ? path.resolve(bundleDir) : null;
  const media = mediaPath ? path.resolve(mediaPath) : null;
  const events = new EventEmitter();
  const activeSockets = new Set(), websocketPeers = new Map(), timers = new Set();
  let server, origin, closed = false, commandDelayMs = 0, commandResponseMs = 0, responseDelayMs = 0, reportDelayMs = 0;
  const initial = identity => ({ Id: identity.sessionId, DeviceId: identity.deviceId,
    DeviceName: identity.deviceName, Client: identity.client, UserId: identity.userId,
    UserName: identity.userId, ServerId: C.serverId, IsActive: true,
    LastActivityDate: new Date().toISOString(), SupportsMediaControl: false,
    SupportsRemoteControl: false, SupportedCommands: [], Capabilities: { SupportedCommands: [] } });
  const sessions = new Map(['receiver', 'controller', 'foreign'].map(role => {
    const identity = { ...C[role], userId: role === 'foreign' ? C.foreignUserId : C.userId };
    return [identity.sessionId, initial(identity)];
  }));
  const trap = (id, name, stale, enabled) => ({
    ...initial({ sessionId: id, deviceId: `${id}-device`, deviceName: name, client: 'JMS', userId: C.userId }),
    SupportsMediaControl: enabled, SupportsRemoteControl: enabled, SupportedCommands: enabled ? commandTypes : [],
    Capabilities: { SupportedCommands: enabled ? commandTypes : [] },
    LastActivityDate: new Date(Date.now() - (stale ? 90000 : 0)).toISOString(), _stale: stale,
    NowPlayingItem: { Id: C.itemId, RunTimeTicks: durationTicks },
    PlaylistItemId: C.playbackId, LastPlaybackCheckIn: new Date().toISOString(),
    PlayState: { MediaSourceId: C.sourceA, SubtitleStreamIndex: -1, PositionTicks: 0, IsPaused: true, CanSeek: true },
  });
  sessions.set('stale-fixture-session', trap('stale-fixture-session', 'Stale fixture', true, true));
  sessions.set('disabled-fixture-session', trap('disabled-fixture-session', 'Disabled fixture', false, false));
  const foreign = sessions.get(C.foreign.sessionId);
  Object.assign(foreign, trap(C.foreign.sessionId, C.foreign.deviceName, false, true),
    { UserId: C.foreignUserId, DeviceId: C.foreign.deviceId });
  const state = { requests: [], commands: [], reports: [], capabilities: [], sockets: [],
    mediaRequests: [], subtitleRequests: [], denied: [], failures: [], sessions,
    deliberatelyUnfilteredNegativeSessions: true };
  const record = (list, value) => {
    assert.ok(list.length < 10000, 'Fixture ledger limit'); list.push(value); events.emit('change');
  };
  const timestamp = old => new Date(Math.max(Date.now(), Date.parse(old || 0) + 1 || 0)).toISOString();
  const cleanSession = session => {
    const value = clone(session); delete value._stale;
    if (session._stale) value.LastActivityDate = new Date(Date.now() - 90000).toISOString();
    return value;
  };
  const reply = (res, status, value) => {
    if (res.destroyed || res.writableEnded) return;
    res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(value === undefined ? undefined : JSON.stringify(value));
  };
  const later = (fn, ms) => {
    if (!ms) { fn(); return; }
    const timer = setTimeout(() => { timers.delete(timer); if (!closed) fn(); }, ms);
    timers.add(timer);
  };
  const sendCommand = (command, sessionId) => {
    const session = sessions.get(sessionId);
    if (!session) return false;
    let delivered = false;
    for (const peer of websocketPeers.values()) {
      if (peer.identity.sessionId === sessionId && peer.identity.deviceId === session.DeviceId && !peer.socket.destroyed) {
        peer.socket.write(encodeFrame(JSON.stringify({ MessageType: 'GeneralCommand', Data: clone(command) })));
        delivered = true;
      }
    }
    return delivered;
  };
  const readBody = async req => {
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; assert.ok(size <= 65536, 'Request size limit'); chunks.push(chunk); }
    const text = Buffer.concat(chunks).toString('utf8'); return text ? JSON.parse(text) : {};
  };
  const serveFile = (req, res, file, type = mime(file)) => {
    const stat = fs.statSync(file); assert.ok(stat.isFile(), 'Expected fixture file');
    let start = 0, end = stat.size - 1, status = 200;
    if (req.headers.range) {
      const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
      if (!match) { res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` }); res.end(); return; }
      start = Number(match[1]); end = match[2] ? Number(match[2]) : end;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= stat.size) {
        res.writeHead(416, { 'Content-Range': `bytes */${stat.size}` }); res.end(); return;
      }
      end = Math.min(end, stat.size - 1); status = 206;
    }
    const headers = { 'Content-Type': type, 'Cache-Control': 'no-store', 'Accept-Ranges': 'bytes',
      'Content-Length': end - start + 1 };
    if (status === 206) headers['Content-Range'] = `bytes ${start}-${end}/${stat.size}`;
    res.writeHead(status, headers);
    if (req.method === 'HEAD') res.end();
    else fs.createReadStream(file, { start, end }).on('error', () => res.destroy()).pipe(res);
  };

  async function handle(req, res) {
    try {
      assert.equal(req.headers.host, new URL(origin).host, 'Unexpected fixture host');
      const url = new URL(req.url, origin);
      assert.equal(url.origin, origin, 'Absolute external request rejected');
      const pathname = decodeURIComponent(url.pathname);
      assert.ok(!pathname.includes('\\') && !pathname.includes('\0') && !pathname.split('/').includes('..'), 'Unsafe fixture path');
      if (req.method === 'OPTIONS') { reply(res, 204); return; }
      if (pathname === '/jms-config.json' || pathname === '/assets/config/config.json') {
        reply(res, 200, { baseUrl: origin, seerrBaseUrl: null, diagnosticsEndpoint: null }); return;
      }
      if (pathname === '/System/Info/Public') {
        reply(res, 200, { Id: C.serverId, ServerName: 'Owned loopback fixture', Version: '10.11.0',
          StartupWizardCompleted: true, LocalAddress: origin }); return;
      }
      if (['/fixture/media.mp4', '/remote-fixture.mp4'].includes(pathname)) {
        record(state.mediaRequests, { method: req.method, range: req.headers.range || null });
        assert.ok(media && ['GET', 'HEAD'].includes(req.method), 'Local media required');
        serveFile(req, res, media, 'video/mp4'); return;
      }
      const subtitle = /^\/(?:fixture\/)?subtitles\/(source-a|source-b)\/(3|7)\.vtt$/.exec(pathname);
      if (subtitle) {
        const [, source, index] = subtitle;
        const text = source === C.sourceB ? 'WRONG SOURCE SUBTITLE' : index === '3' ? 'SOURCE A SUBTITLE CUE' : 'SUBTITLE B CUE';
        record(state.subtitleRequests, { sourceId: source, index: Number(index) });
        res.writeHead(200, { 'Content-Type': 'text/vtt; charset=utf-8', 'Cache-Control': 'no-store' });
        res.end(`WEBVTT\n\n00:00.000 --> 00:30.000\n${text}\n`); return;
      }
      const apiPath = /^\/(Sessions(?:\/|$)|Items(?:\/|$)|Users(?:\/|$)|System\/Info$)/.test(pathname);
      if (apiPath) {
        const identity = authenticated(req);
        if (!identity) { record(state.denied, { method: req.method, path: pathname, reason: 'authentication' }); reply(res, 401, { Error: 'Synthetic authentication required' }); return; }
        const safeQuery = Object.fromEntries([...url.searchParams].filter(([key]) =>
          ['deviceId', 'activeWithinSeconds', 'controllableByUserId', 'ids', 'fields', 'userId', 'enableUserData'].includes(key)));
          if (url.searchParams.getAll('fields').length > 1) safeQuery.fields = url.searchParams.getAll('fields');
        record(state.requests, { method: req.method, path: pathname, query: safeQuery,
          role: identity.role, userId: identity.userId, deviceId: identity.deviceId });
        if (responseDelayMs) await sleep(responseDelayMs);
        if (closed) { res.destroy(); return; }
        const own = sessions.get(identity.sessionId);
        if (pathname === '/Sessions' && req.method === 'GET') {
          if (url.searchParams.get('activeWithinSeconds') !== '30') { reply(res, 400, { Error: 'Bounded activity query required' }); return; }
          const device = url.searchParams.get('deviceId');
          if (device !== null) {
            reply(res, 200, device === identity.deviceId ? [cleanSession(own)] : []); return;
          }
          if (url.searchParams.get('controllableByUserId') !== identity.userId) {
            reply(res, 400, { Error: 'Current account filter required' }); return;
          }
          // Deliberately include negative fixtures to exercise client validation.
          reply(res, 200, [...sessions.values()].map(cleanSession)); return;
        }
        if (pathname === '/Sessions/Capabilities/Full' && req.method === 'POST') {
          const body = await readBody(req);
          if (url.searchParams.has('id')) { reply(res, 400, { Error: 'Capabilities must be account-captured' }); return; }
          const commands = body.SupportedCommands || [];
          if (!Array.isArray(commands) || commands.some(value => !commandTypes.includes(value))) { reply(res, 400, { Error: 'Unsupported fixture capability' }); return; }
          own.SupportsMediaControl = body.SupportsMediaControl === true;
          own.SupportsRemoteControl = own.SupportsMediaControl && commandTypes.every(value => commands.includes(value));
          own.SupportedCommands = [...commands]; own.Capabilities = clone(body);
          own.LastActivityDate = timestamp(own.LastActivityDate);
          record(state.capabilities, { sessionId: own.Id, enabled: own.SupportsRemoteControl, body: clone(body), at: Date.now() });
          reply(res, 204); return;
        }
        if (['/Sessions/Playing', '/Sessions/Playing/Progress'].includes(pathname) && req.method === 'POST') {
          const body = await readBody(req);
          if (reportDelayMs) await sleep(reportDelayMs);
          if (closed) { res.destroy(); return; }
          if (body.SessionId != null) { reply(res, 400, { Error: 'Reports must omit SessionId' }); return; }
          const source = body.MediaSourceId || C.sourceA;
          if (body.ItemId !== C.itemId || ![C.sourceA, C.sourceB].includes(source) ||
              typeof body.PlaylistItemId !== 'string' || !body.PlaylistItemId.startsWith('jms-remote-')) {
            reply(res, 400, { Error: 'Invalid synthetic playback binding' }); return;
          }
          own.NowPlayingItem = { Id: C.itemId, Name: 'Original loopback remote-control clip', RunTimeTicks: durationTicks };
          own.PlaylistItemId = body.PlaylistItemId;
          own.PlayState = { MediaSourceId: source, PositionTicks: body.PositionTicks || 0,
            IsPaused: body.IsPaused === true, CanSeek: body.CanSeek === true,
            SubtitleStreamIndex: body.SubtitleStreamIndex, AudioStreamIndex: body.AudioStreamIndex };
          own.LastPlaybackCheckIn = timestamp(own.LastPlaybackCheckIn);
          own.LastActivityDate = timestamp(own.LastActivityDate);
          record(state.reports, { sessionId: own.Id, body: clone(body), checkIn: own.LastPlaybackCheckIn, at: Date.now() });
          reply(res, 204); return;
        }
        const commandPath = /^\/Sessions\/([^/]+)\/Command$/.exec(pathname);
        if (commandPath && req.method === 'POST') {
          const target = sessions.get(commandPath[1]), body = await readBody(req);
          if (!target || target.UserId !== identity.userId) { reply(res, 403, { Error: 'Synthetic target denied' }); return; }
          if (!validCommand(body) || body.Arguments.JmsTargetSessionId !== target.Id) { reply(res, 400, { Error: 'Invalid JMS command envelope' }); return; }
          // Jellyfin replaces client-supplied ownership with the authenticated UID.
          const command = { ...body, ControllingUserId: identity.userId };
          const entry = { targetSessionId: target.Id, controllerSessionId: identity.sessionId,
            controllingUserId: identity.userId, command: clone(command), acceptedAt: Date.now(), deliveredAt: null, delivered: false };
          record(state.commands, entry);
          later(() => { entry.delivered = sendCommand(command, target.Id); entry.deliveredAt = Date.now(); events.emit('change'); }, commandDelayMs);
          if (commandResponseMs) await sleep(commandResponseMs);
          reply(res, 204); return;
        }
        if ((pathname === '/Items' || /^\/Users\/[^/]+\/Items$/.test(pathname)) && req.method === 'GET') {
          if (url.searchParams.get('ids') !== C.itemId) { reply(res, 400, { Error: 'Exact synthetic item required' }); return; }
          if (!hasSubtitleMetadataFields(url)) { reply(res, 400, { Error: 'Exact subtitle metadata fields required' }); return; }
          reply(res, 200, { Items: [itemMetadata(durationTicks)], TotalRecordCount: 1, StartIndex: 0 }); return;
        }
        if (pathname === '/Users/Me' && req.method === 'GET') { reply(res, 200, { Id: identity.userId, Name: identity.userId, Configuration: {}, Policy: { EnableRemoteControlOfOtherUsers: false } }); return; }
        if (pathname === '/System/Info' && req.method === 'GET') { reply(res, 200, { Id: C.serverId, ServerName: 'Owned loopback fixture', Version: '10.11.0' }); return; }
        record(state.denied, { method: req.method, path: pathname, reason: 'unknown-api' });
        reply(res, 404, { Error: 'Outside the synthetic fixture API' }); return;
      }
      if (!['GET', 'HEAD'].includes(req.method) || !bundle) { reply(res, 404); return; }
      const relative = pathname.replace(/^\/+/, '') || 'index.html';
      const file = path.resolve(bundle, relative);
      assert.ok(file === bundle || file.startsWith(bundle + path.sep), 'Bundle traversal rejected');
      if (!fs.existsSync(file)) { reply(res, 404); return; }
      const real = fs.realpathSync(file), realBundle = fs.realpathSync(bundle);
      assert.ok(real.startsWith(realBundle + path.sep), 'Bundle symlink escape rejected');
      serveFile(req, res, real);
    } catch (error) {
      record(state.failures, { kind: error.name, category: 'request-rejected' });
      reply(res, 400, { Error: 'Synthetic fixture request rejected' });
    }
  }

  function upgrade(req, socket, head) {
    try {
      const url = new URL(req.url, origin);
      assert.equal(req.headers.host, new URL(origin).host);
      assert.equal(url.origin, origin); assert.equal(url.pathname, '/socket');
      const identity = identityFor(url.searchParams.get('ApiKey') || url.searchParams.get('api_key'));
      assert.ok(identity && url.searchParams.get('deviceId') === identity.deviceId, 'Socket identity mismatch');
      assert.ok(!req.headers.origin || req.headers.origin === origin, 'Socket origin mismatch');
      assert.equal(String(req.headers.upgrade).toLowerCase(), 'websocket');
      assert.equal(req.headers['sec-websocket-version'], '13');
      const key = req.headers['sec-websocket-key'];
      assert.ok(typeof key === 'string' && Buffer.from(key, 'base64').length === 16, 'Invalid socket key');
      const accept = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
      socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
      const own = sessions.get(identity.sessionId);
      own.LastActivityDate = timestamp(own.LastActivityDate);
      const peer = { socket, identity, buffer: Buffer.alloc(0) }; websocketPeers.set(socket, peer);
      record(state.sockets, { event: 'connected', sessionId: identity.sessionId, deviceId: identity.deviceId, at: Date.now() });
      const consume = data => {
        try {
          peer.buffer = Buffer.concat([peer.buffer, data]); assert.ok(peer.buffer.length <= 65544, 'Socket receive budget');
          const decoded = decodeClientFrames(peer.buffer); peer.buffer = decoded.remainder;
          for (const frame of decoded.messages) {
            if (frame.opcode === 8) { socket.end(encodeFrame(frame.payload, 8)); return; }
            if (frame.opcode === 9) socket.write(encodeFrame(frame.payload, 10));
            if (frame.opcode === 1) {
              const message = JSON.parse(frame.payload.toString('utf8'));
              assert.equal(message.MessageType, 'KeepAlive', 'Only KeepAlive accepted by fixture');
              sessions.get(identity.sessionId).LastActivityDate = timestamp(sessions.get(identity.sessionId).LastActivityDate);
            }
          }
        } catch (_) { socket.destroy(); }
      };
      socket.on('data', consume); socket.on('error', () => {});
      socket.on('close', () => { websocketPeers.delete(socket); record(state.sockets, { event: 'disconnected', sessionId: identity.sessionId, at: Date.now() }); });
      if (head.length) consume(head);
    } catch (_) { record(state.denied, { method: 'UPGRADE', path: '/socket', reason: 'socket-authentication' }); socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); }
  }

  return {
    state, events, constants: C,
    get origin() { assert.ok(origin, 'Fixture not started'); return origin; },
    async start() {
      assert.ok(!server && !closed, 'Fixture is single-use');
      if (bundle) assert.ok(fs.statSync(bundle).isDirectory(), 'Bundle directory missing');
      if (media) assert.ok(fs.statSync(media).isFile(), 'Original local media missing');
      server = http.createServer(handle); server.on('upgrade', upgrade);
      server.on('connection', socket => { activeSockets.add(socket); socket.on('close', () => activeSockets.delete(socket)); });
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen({ host, port, exclusive: true }, resolve); });
      assert.equal(server.address().address, host); origin = `http://${host}:${server.address().port}`;
      return this;
    },
    setCommandDelay(ms, { responseMs = 0 } = {}) {
      assert.ok(Number.isInteger(ms) && ms >= 0 && ms <= 20000);
      assert.ok(Number.isInteger(responseMs) && responseMs >= 0 && responseMs <= 20000);
      commandDelayMs = ms; commandResponseMs = responseMs;
    },
    setResponseDelay(ms) { assert.ok(Number.isInteger(ms) && ms >= 0 && ms <= 15000); responseDelayMs = ms; },
    setReportDelay(ms) { assert.ok(Number.isInteger(ms) && ms >= 0 && ms <= 15000); reportDelayMs = ms; },
    disconnectReceiver() { for (const peer of websocketPeers.values()) if (peer.identity.role === 'receiver') peer.socket.end(encodeFrame(Buffer.from([3, 233]), 8)); },
    injectCommand(command, { sessionId = C.receiver.sessionId } = {}) { return sendCommand(command, sessionId); },
    setSessionStale(sessionId = C.receiver.sessionId, stale = true) { assert.ok(sessions.has(sessionId)); sessions.get(sessionId)._stale = stale; events.emit('change'); },
    changeSource(sourceId) { assert.ok([C.sourceA, C.sourceB].includes(sourceId)); const session = sessions.get(C.receiver.sessionId); assert.ok(session.PlayState); session.PlayState.MediaSourceId = sourceId; session.LastPlaybackCheckIn = timestamp(session.LastPlaybackCheckIn); },
    async close() {
      if (closed) return; closed = true;
      for (const timer of timers) clearTimeout(timer); timers.clear();
      for (const socket of activeSockets) socket.destroy();
      if (server?.listening) await new Promise(resolve => server.close(resolve));
      events.removeAllListeners();
    },
  };
}

// Pure checks: never create a listener, read a bundle, spawn or fetch.
export function runFixtureUnitChecks() {
  const command = { Name: 'PlayState', ControllingUserId: 'ignored-client-value', Arguments: {
    JmsRemoteVersion: '1', JmsTargetSessionId: C.receiver.sessionId, JmsItemId: C.itemId,
    JmsMediaSourceId: C.sourceA, JmsPlaybackId: C.playbackId, JmsControllerId: 'controller-test',
    JmsRequestId: 'request-test', JmsSequence: '1', JmsIssuedAt: '2026-11-02T00:00:00.000Z',
    JmsExpiresAt: '2026-11-02T00:00:10.000Z', Command: 'Pause' } };
  assert.ok(validCommand(command));
  assert.ok(!validCommand({ ...command, Arguments: { ...command.Arguments, Unknown: 'x' } }));
  assert.ok(!validCommand({ ...command, Arguments: { ...command.Arguments, JmsSequence: 1 } }));
  assert.ok(!validCommand({ ...command, Arguments: { ...command.Arguments, Command: 'Seek' } }));
  assert.ok(validCommand({ ...command, Name: 'SetSubtitleStreamIndex', Arguments: {
    ...Object.fromEntries(metadataKeys.map(key => [key, command.Arguments[key]])), Index: '-1' } }));
  const payload = Buffer.from('{"MessageType":"KeepAlive"}'), mask = Buffer.from([1, 2, 3, 4]);
  const wire = Buffer.concat([Buffer.from([0x81, 0x80 | payload.length]), mask,
    Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]))]);
  const decoded = decodeClientFrames(wire);
  assert.equal(decoded.messages[0].payload.toString(), payload.toString()); assert.equal(decoded.remainder.length, 0);
  assert.equal(decodeClientFrames(wire.subarray(0, 4)).messages.length, 0);
  assert.throws(() => decodeClientFrames(Buffer.from([0x81, 0])));
  assert.throws(() => createRemoteControlFixture({ host: '0.0.0.0' }));
  const fixture = createRemoteControlFixture(); assert.equal(fixture.state.commands.length, 0);
  const metadata = itemMetadata(C.durationTicks);
  assert.equal(metadata.MediaSources[0].MediaStreams[0].Index, metadata.MediaSources[1].MediaStreams[0].Index);
  assert.notEqual(metadata.MediaSources[0].MediaStreams[0].DisplayTitle, metadata.MediaSources[1].MediaStreams[0].DisplayTitle);
  assert.equal(hasSubtitleMetadataFields(new URL('http://127.0.0.1/?fields=MediaSources,MediaStreams')), true);
  assert.equal(hasSubtitleMetadataFields(new URL('http://127.0.0.1/?fields=MediaSources&fields=MediaStreams')), true);
  assert.equal(hasSubtitleMetadataFields(new URL('http://127.0.0.1/?fields=MediaStreams')), false);
  assert.equal(hasSubtitleMetadataFields(new URL('http://127.0.0.1/?fields=MediaSources,MediaStreams,Other')), false);
  assert.equal(hasSubtitleMetadataFields(new URL('http://127.0.0.1/?fields=MediaSources,MediaStreams&fields=MediaStreams')), false);
  return { status: 'PASS', checks: 17, networkStarted: false, browserStarted: false };
}
