export const evaluate: (script: string) => string;
export const evaluateAsync: (script: string, onHost: (id: number, request: string) => void, contextJson?: string) => Promise<string>;
export const resolveHost: (id: number, response: string) => void;
export const resolveFetch: (id: number, response: string) => void;
