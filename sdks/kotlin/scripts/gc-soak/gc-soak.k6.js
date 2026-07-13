import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL;
const HOSTH = __ENV.HOST_HEADER;
const AGENTS = parseInt(__ENV.AGENTS, 10);
const RATE = parseInt(__ENV.RATE, 10);
const VUS = parseInt(__ENV.VUS, 10);
const CHURN = parseInt(__ENV.CHURN_OBJECTS || '20000', 10);
// Soak/smoke: fail on any non-200. Regression matrix sets ENFORCE_THRESHOLDS=0.
const ENFORCE = (__ENV.ENFORCE_THRESHOLDS || '1') !== '0';

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION,
      preAllocatedVUs: VUS,
      maxVUs: VUS,
    },
  },
  thresholds: ENFORCE
    ? {
        http_req_failed: ['rate==0'],
        checks: ['rate==1'],
      }
    : {},
};

export default function () {
  const id = Math.floor(Math.random() * AGENTS);
  // Path n = allocation count (GC workload). Timeout covers heavy concurrent churn.
  const res = http.post(`${BASE}/gcstress/${id}/churn/${CHURN}`, null, {
    headers: { Host: HOSTH },
    timeout: __ENV.REQ_TIMEOUT || '120s',
    tags: { churn: String(CHURN), vus_target: String(VUS) },
  });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const dir = __ENV.WORKDIR || '.';
  return { [`${dir}/k6-summary.json`]: JSON.stringify(data, null, 2) };
}
