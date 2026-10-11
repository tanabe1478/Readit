// Each SDK call gets fresh compiler state; diagnostics and source maps are global
// inside the official worker compiler. This is a build worker, not an AI loop.
import { parentPort, workerData } from 'node:worker_threads';

try {
  const compiler = (await import(workerData.compiler)).default;
  if (!['buildPackage', 'linkCore'].includes(workerData.method)) {
    throw new Error('Unsupported compiler operation');
  }
  const result = compiler[workerData.method](workerData.params);
  parentPort.postMessage({ result });
} catch (error) {
  parentPort.postMessage({ error: String(error) });
}
