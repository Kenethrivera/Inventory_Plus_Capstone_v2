CREATE TABLE "public"."forecast_replenishment_configs" (
  "product_id" uuid NOT NULL,
  "location_id" uuid NOT NULL,
  "supplier_lead_time_days" integer,
  "review_period_days" integer,
  "safety_stock" numeric,
  "minimum_order_quantity" numeric,
  "supplier_pack_size" numeric,
  "supplier_order_unit" text,
  "unit_conversion_factor" numeric,
  "confirmed_incoming_quantity" numeric,
  "incoming_quantity_verified" boolean NOT NULL DEFAULT false,
  "backorder_quantity" numeric,
  "backorder_quantity_verified" boolean NOT NULL DEFAULT false,
  "supplier_availability" text,
  "data_source" text NOT NULL,
  "source_captured_at" timestamp with time zone NOT NULL,
  "rationale" text,
  "updated_at" timestamp with time zone NOT NULL DEFAULT now(),
  "updated_by_profile_id" bigint NOT NULL,
  CONSTRAINT "forecast_replenishment_configs_pkey" PRIMARY KEY (product_id, location_id),
  CONSTRAINT "forecast_replenishment_configs_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE,
  CONSTRAINT "forecast_replenishment_configs_location_id_fkey" FOREIGN KEY (location_id) REFERENCES public.locations(id) ON DELETE CASCADE,
  CONSTRAINT "forecast_replenishment_configs_updated_by_fkey" FOREIGN KEY (updated_by_profile_id) REFERENCES public.profiles(id),
  CONSTRAINT "forecast_replenishment_lead_time_check" CHECK (supplier_lead_time_days IS NULL OR supplier_lead_time_days BETWEEN 0 AND 3650),
  CONSTRAINT "forecast_replenishment_review_period_check" CHECK (review_period_days IS NULL OR review_period_days BETWEEN 0 AND 365),
  CONSTRAINT "forecast_replenishment_safety_stock_check" CHECK (safety_stock IS NULL OR (safety_stock >= 0 AND safety_stock <> 'NaN'::numeric)),
  CONSTRAINT "forecast_replenishment_moq_check" CHECK (minimum_order_quantity IS NULL OR (minimum_order_quantity >= 0 AND minimum_order_quantity <> 'NaN'::numeric)),
  CONSTRAINT "forecast_replenishment_pack_size_check" CHECK (supplier_pack_size IS NULL OR (supplier_pack_size > 0 AND supplier_pack_size <> 'NaN'::numeric)),
  CONSTRAINT "forecast_replenishment_conversion_check" CHECK (unit_conversion_factor IS NULL OR (unit_conversion_factor > 0 AND unit_conversion_factor <> 'NaN'::numeric)),
  CONSTRAINT "forecast_replenishment_conversion_unit_check" CHECK (unit_conversion_factor IS NULL OR nullif(btrim(supplier_order_unit), '') IS NOT NULL),
  CONSTRAINT "forecast_replenishment_incoming_check" CHECK ((confirmed_incoming_quantity IS NULL AND NOT incoming_quantity_verified) OR (confirmed_incoming_quantity >= 0 AND confirmed_incoming_quantity <> 'NaN'::numeric AND incoming_quantity_verified)),
  CONSTRAINT "forecast_replenishment_backorder_check" CHECK ((backorder_quantity IS NULL AND NOT backorder_quantity_verified) OR (backorder_quantity >= 0 AND backorder_quantity <> 'NaN'::numeric AND backorder_quantity_verified)),
  CONSTRAINT "forecast_replenishment_availability_check" CHECK (supplier_availability IS NULL OR supplier_availability IN ('available', 'unavailable', 'unknown')),
  CONSTRAINT "forecast_replenishment_source_check" CHECK (data_source IN ('admin_estimate', 'verified_record')),
  CONSTRAINT "forecast_replenishment_rationale_check" CHECK (data_source <> 'admin_estimate' OR nullif(btrim(rationale), '') IS NOT NULL)
);

CREATE INDEX forecast_replenishment_configs_location_idx
  ON public.forecast_replenishment_configs (location_id, product_id);

ALTER TABLE public.forecast_replenishment_configs ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.forecast_replenishment_configs
  FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.forecast_replenishment_configs
  TO postgres;
