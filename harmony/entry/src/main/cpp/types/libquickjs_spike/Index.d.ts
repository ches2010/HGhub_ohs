export const evaluate: (script: string) => string;
export const evaluateAsync: (script: string, onFetch: (id: number, request: string) => void) => Promise<string>;
export const resolveFetch: (id: number, result: string) => void;
