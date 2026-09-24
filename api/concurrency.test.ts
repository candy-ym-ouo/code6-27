import assert from 'node:assert/strict';
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { rmSync } from 'node:fs';
import { join } from 'node:path';

const PORT = 3199;
const DATA_FILE = 'data.concurrency-test.json';
const base = `http://localhost:${PORT}/api/v1`;
const dataPath = join(process.cwd(), DATA_FILE);
let server: ChildProcess | undefined;

function startServer(): ChildProcess {
  return spawn('npx', ['tsx', 'api/server.ts'], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(PORT), DATA_FILE },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
}
async function waitReady(server: ChildProcess) {
  let buf = '';
  server.stdout!.on('data', (c) => { buf += c; });
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://localhost:${PORT}/health/live`);
      if (r.ok) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('server did not start. output: ' + buf);
}
async function stopServer(server: ChildProcess) {
  server.kill('SIGTERM');
  await once(server, 'exit').catch(() => {});
}

async function call(method: string, path: string, body?: unknown, key?: string) {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (key) headers['Idempotency-Key'] = key;
  return fetch(base + path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
}
const j = async (r: Response) => r.json();

function draft(actorId: string, extra: Record<string, unknown> = {}) {
  return {
    playId: 'moon',
    assignments: {},
    timeline: [{ actionId: 'bow', actorIds: [actorId], act: 0, slot: 0 }],
    endings: [0, 1, 2],
    ...extra,
  };
}

async function main() {
  rmSync(dataPath, { force: true });
  server = startServer();
  await waitReady(server);

  // 准备一个处于 PREPARING 的巡演
  const created = await j(await call('POST', '/tours', { name: '边界剧团' }));
  const id = created.tour.id;
  const actorId = created.tour.actors[0].id;
  await call('POST', `/tours/${id}/investigations`, { kind: 'market' });

  // 1) 缺少草稿版本号必须被拒绝
  let r = await call('PUT', `/tours/${id}/production`, draft(actorId));
  assert.equal(r.status, 428, '无版本号保存应返回 428');
  assert.equal((await j(r)).code, 'VERSION_REQUIRED');

  // 2) 首个合法保存：版本 0 -> 1
  r = await call('PUT', `/tours/${id}/production`, draft(actorId, { expectedVersion: 0 }));
  assert.equal(r.status, 200, '版本 0 的首次保存应成功');
  const saved1 = await j(r);
  assert.equal(saved1.draftVersion, 1);

  // 3) 并发保存：两个请求都基于版本 1，只有一个能赢
  const [a, b] = await Promise.all([
    call('PUT', `/tours/${id}/production`, draft(actorId, { expectedVersion: 1, endings: [1, 1, 1] })),
    call('PUT', `/tours/${id}/production`, draft(actorId, { expectedVersion: 1, endings: [2, 2, 2] })),
  ]);
  const statuses = [a.status, b.status].sort();
  assert.deepEqual(statuses, [200, 409], '并发保存必须一成一败');
  const winnerRes = a.status === 200 ? a : b;
  const loserRes = a.status === 200 ? b : a;
  const winner = await j(winnerRes);
  assert.equal(winner.draftVersion, 2);
  assert.equal((await j(loserRes)).code, 'STALE_COMMIT');

  // 4) 演出不能使用未保存草稿：
  //    4a) 夹带进版本不匹配的完整草稿 -> 409 STALE_COMMIT
  r = await call('POST', `/tours/${id}/performances`, draft(actorId, { expectedVersion: 1 }), undefined);
  assert.equal(r.status, 409);
  assert.equal((await j(r)).code, 'STALE_COMMIT');
  //    4b) 即使夹带的草稿内容合法且自报当前版本，也不得绕过已保存草稿（内容不同 -> 409）
  r = await call('POST', `/tours/${id}/performances`, draft(actorId, { expectedVersion: 2, endings: [0, 0, 0] }));
  assert.equal(r.status, 409);
  //    4c) 版本过期（1）的纯版本号提交 -> 409
  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 1 });
  assert.equal(r.status, 409);
  //    4d) 不带版本号 -> 428
  r = await call('POST', `/tours/${id}/performances`, {});
  assert.equal(r.status, 428);
  //    4e) 只有“版本号与服务端已保存草稿一致”才允许演出，快照必须来自已保存草稿
  const idemKey = 'fixed-key-for-restart-replay';
  const fundsBefore = (await j(await call('GET', `/tours/${id}`))).tour.funds;
  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 2 }, idemKey);
  assert.equal(r.status, 200);
  const perf1 = await j(r);
  assert.equal(perf1.performance.snapshot.endings.join(','), winner.tour.draft.endings.join(','), '快照必须来自已保存草稿');
  assert.equal(perf1.performance.draftVersion, 2);
  assert.equal(perf1.draftVersion, 3, '演出消费草稿后版本边界必须推进');

  // 5) 进程内即时重放：不二次结算
  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 2 }, idemKey);
  assert.equal(r.status, 200);
  const replay = await j(r);
  assert.equal(replay.replayed, true);
  assert.equal(replay.performance.id, perf1.performance.id);
  const fundsAfterReplay = (await j(await call('GET', `/tours/${id}`))).tour.funds;
  assert.equal(fundsAfterReplay, fundsBefore + perf1.performance.income, '即时重放不得二次结算');

  // 陈旧重放：同 key 但版本号对不上 -> 409
  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 1 }, idemKey);
  assert.equal(r.status, 409, '陈旧版本号的重放必须被拒绝');
  assert.equal((await j(r)).code, 'STALE_COMMIT');
  // 篡改重放内容 -> 409
  r = await call('POST', `/tours/${id}/performances`, draft(actorId, { expectedVersion: 2 }), idemKey);
  assert.equal(r.status, 409, '夹带不同草稿的重放必须被拒绝');

  // 6) 重启服务器后重放：幂等记录来自持久化存档，仍共用同一条版本边界
  await stopServer(server);
  server = startServer();
  await waitReady(server);

  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 2 }, idemKey);
  assert.equal(r.status, 200, '重启后合法重放应返回原快照');
  const replayAfterRestart = await j(r);
  assert.equal(replayAfterRestart.replayed, true);
  assert.equal(replayAfterRestart.performance.id, perf1.performance.id, '重启后重放必须命中同一条演出记录');
  assert.deepEqual(replayAfterRestart.performance.snapshot, perf1.performance.snapshot);
  const fundsAfterRestart = (await j(await call('GET', `/tours/${id}`))).tour.funds;
  assert.equal(fundsAfterRestart, fundsAfterReplay, '重启后重放不得二次结算');

  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 2 }, idemKey);
  assert.equal(r.status, 200);
  assert.equal((await j(r)).performance.id, perf1.performance.id);

  // 重启后陈旧重放同样被拒
  r = await call('POST', `/tours/${id}/performances`, { expectedVersion: 99 }, idemKey);
  assert.equal(r.status, 409, '重启后陈旧提交必须被拒绝');

  // 7) 演出后旧版本号彻底失效，必须重新拉取并保存新草稿
  await call('POST', `/tours/${id}/investigations`, { kind: 'tavern' });
  r = await call('PUT', `/tours/${id}/production`, draft(actorId, { expectedVersion: 2 }));
  assert.equal(r.status, 409, '演出后旧版本保存必须被拒绝');
  r = await call('PUT', `/tours/${id}/production`, draft(actorId, { expectedVersion: 3 }));
  assert.equal(r.status, 200, '基于最新版本边界的保存应成功');

  await stopServer(server);
  rmSync(dataPath, { force: true });
  console.log('concurrency / version boundary tests passed');
}

main().catch(async (e) => {
  console.error(e);
  try { await stopServer(server!); } catch {}
  rmSync(dataPath, { force: true });
  process.exit(1);
});
