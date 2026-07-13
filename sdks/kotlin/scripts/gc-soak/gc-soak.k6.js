import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE_URL;
const HOSTH = __ENV.HOST_HEADER;
const AGENTS = parseInt(__ENV.AGENTS, 10);
const RATE = parseInt(__ENV.RATE, 10);
const VUS = parseInt(__ENV.VUS, 10);

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
  thresholds: {
    http_req_failed: ['rate==0'], // any failed request -> non-zero k6 exit
    checks: ['rate==1'],
  },
};

export default function () {
  const id = Math.floor(Math.random() * AGENTS); // spread across thousands of distinct agents
  const res = http.post(`${BASE}/gcstress/${id}/churn`, null, { headers: { Host: HOSTH } });
  check(res, { 'status 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  const dir = __ENV.WORKDIR || '.';
  return { [`${dir}/k6-summary.json`]: JSON.stringify(data, null, 2) };
}
