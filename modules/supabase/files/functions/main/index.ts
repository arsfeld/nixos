import { serve } from "https://deno.land/std@0.177.1/http/server.ts"

serve(async () => {
  return new Response(
    `"Hello from Main Function!"`,
    { headers: { "Content-Type": "application/json" } },
  )
})