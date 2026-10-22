import { z } from "zod";

export const contextAssemblyBenchmarkDataSchema = z.object({
  profile: z.literal("stub"),
  rps: z.number().int().min(1),
  duration_s: z.number().positive(),
  attempted: z.number().int().nonnegative(),
  succeeded: z.number().int().nonnegative(),
  failed: z.number().int().nonnegative(),
  error_rate: z.number().min(0).max(1),
  mean_ms: z.number().nonnegative(),
  p50_ms: z.number().nonnegative(),
  p95_ms: z.number().nonnegative(),
  p99_ms: z.number().nonnegative(),
}).strict();

export type ContextAssemblyBenchmarkDataParsed = z.infer<
  typeof contextAssemblyBenchmarkDataSchema
>;
