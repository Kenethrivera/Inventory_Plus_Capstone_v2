CREATE TABLE "public"."product_forecasts" (
  "id"               uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "product_name"     text                     NOT NULL,
  "forecast_type"    text                     NOT NULL,
  "predicted_demand" numeric                  NOT NULL,
  "lower_bound"      numeric                  NOT NULL,
  "upper_bound"      numeric                  NOT NULL,
  "trend"            text                     DEFAULT 'Stable'::text,
  "calculated_at"    timestamp with time zone DEFAULT now(),
  CONSTRAINT "product_forecasts_pkey" PRIMARY KEY (id)
);

CREATE INDEX idx_forecast_lookup ON public.product_forecasts USING btree (product_name, forecast_type);

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."product_forecasts" TO "anon", "authenticated";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."product_forecasts" TO "service_role";

REVOKE ALL ON TABLE "public"."product_forecasts" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."product_forecasts" TO "postgres";
