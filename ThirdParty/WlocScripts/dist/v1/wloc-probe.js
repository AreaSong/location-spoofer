/* 独立 HTTPS 探测：只返回固定标识，不访问存储、坐标或网络。 */
const matches = $request.method === 'GET'
  && $request.url === 'https://location-spoofer.invalid/probe';
$done({ response: {
  status: matches ? 200 : 400,
  headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  body: JSON.stringify(matches
    ? { protocol: 'location-spoofer-probe', version: '1', mode: 'no-storage' }
    : { error: 'unsupported probe request' })
} });
