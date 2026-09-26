// Reads a value from a page in a Chromium instance started with --remote-debugging-port,
// polling until the expression returns something. Only used on the throwaway benchmark instance.
// Usage: node cdp-read.mjs <port> <url substring> <expression> [timeout seconds]
const [port, urlPart, expression, timeoutSeconds = "600"] = process.argv.slice(2);
const deadline = Date.now() + Number(timeoutSeconds) * 1000;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function evaluate(wsUrl) {
  const socket = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  const reply = new Promise((resolve) => {
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id === 1) resolve(message.result?.result?.value);
    };
  });
  socket.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, returnByValue: true } }));
  const value = await reply;
  socket.close();
  return value;
}

while (Date.now() < deadline) {
  try {
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const page = pages.find((p) => p.type === "page" && p.url.includes(urlPart));
    if (page) {
      const value = await evaluate(page.webSocketDebuggerUrl);
      if (value) {
        console.log(value);
        process.exit(0);
      }
    }
  } catch (_) {}
  await sleep(3000);
}
console.error("timed out");
process.exit(1);
