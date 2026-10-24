CREATE TABLE "public"."approval_requests" (
  "id"                            uuid                     NOT NULL DEFAULT extensions.gen_random_uuid(),
  "location_id"                   uuid                     NOT NULL,
  "request_type"                  text                     NOT NULL,
  "status"                        text                     NOT NULL DEFAULT 'pending'::text,
  "requested_by_id"               bigint                   NOT NULL,
  "requested_by_name"             text                     NOT NULL,
  "requested_by_role"             text                     NOT NULL,
  "requested_at"                  timestamp with time zone NOT NULL DEFAULT now(),
  "reviewed_by_id"                bigint,
  "reviewed_by_name"              text,
  "reviewed_at"                   timestamp with time zone,
  "product_id"                    uuid,
  "product_name"                  text,
  "product_sku"                   text                     DEFAULT ''::text,
  "unit"                          text                     DEFAULT 'pcs'::text,
  "requested_quantity"            numeric,
  "stock_at_request"              numeric,
  "reason"                        text,
  "note"                          text,
  "review_note"                   text,
  "transaction_id"                uuid,
  "proof_storage_path"            text,
  "proof_file_name"               text,
  "proof_mime_type"               text,
  "discount_mode"                 text,
  "discount_value"                numeric,
  "discount_amount"               numeric,
  "discount_effective_percentage" numeric,
  "subtotal_amount"               numeric,
  "cart_fingerprint"              text,
  "checkout_token"                text,
  "used_at"                       timestamp with time zone,
  "used_order_id"                 uuid,
  "cart_items"                    jsonb,
  CONSTRAINT "approval_request_discount_fields_check"
    CHECK (((request_type <> 'discount'::text) OR ((discount_mode = ANY (ARRAY['percentage'::text, 'amount'::text])) AND (discount_value IS
    NOT NULL) AND (discount_value >= (0)::numeric) AND (discount_amount IS NOT NULL) AND (discount_amount >= (0)::numeric) AND (discount_effective_percentage IS
    NOT NULL) AND (discount_effective_percentage >= (0)::numeric) AND (discount_effective_percentage <= (100)::numeric) AND (subtotal_amount IS
    NOT NULL) AND (subtotal_amount >= (0)::numeric) AND ((cart_items IS NULL) OR ((jsonb_typeof(cart_items) = 'array'::text) AND (jsonb_array_length(cart_items) > 0))) AND
    (cart_fingerprint IS NOT NULL) AND (checkout_token IS NOT NULL) AND (NULLIF(TRIM(BOTH FROM reason), ''::text) IS NOT NULL)))),
  CONSTRAINT "approval_request_inventory_fields_check" CHECK (((request_type = 'discount'::text) OR ((product_id IS NOT NULL) AND (product_name IS NOT NULL) AND (product_sku IS
    NOT NULL) AND (unit IS NOT NULL) AND (requested_quantity IS NOT NULL) AND (requested_quantity > (0)::numeric) AND (stock_at_request IS
    NOT NULL) AND (stock_at_request >= (0)::numeric)))),
  CONSTRAINT "approval_request_write_off_reason" CHECK (((request_type <> 'write_off'::text) OR (NULLIF(TRIM(BOTH FROM reason), ''::text) IS NOT NULL))),
  CONSTRAINT "approval_requests_pkey" PRIMARY KEY (id),
  CONSTRAINT "approval_requests_request_type_check" CHECK ((request_type = ANY (ARRAY['restock'::text, 'write_off'::text, 'discount'::text]))),
  CONSTRAINT "approval_requests_requested_by_role_check" CHECK ((requested_by_role = ANY (ARRAY['helper'::text, 'staff'::text, 'cashier'::text]))),
  CONSTRAINT "approval_requests_requested_quantity_check" CHECK ((requested_quantity > (0)::numeric)),
  CONSTRAINT "approval_requests_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'rejected'::text]))),
  CONSTRAINT "approval_requests_stock_at_request_check" CHECK ((stock_at_request >= (0)::numeric)),
  CONSTRAINT "approval_requests_product_id_fkey" FOREIGN KEY (product_id) REFERENCES public.products(id),
  CONSTRAINT "approval_requests_requested_by_id_fkey" FOREIGN KEY (requested_by_id) REFERENCES public.profiles(id),
  CONSTRAINT "approval_requests_reviewed_by_id_fkey" FOREIGN KEY (reviewed_by_id) REFERENCES public.profiles(id)
);

ALTER TABLE "public"."approval_requests"
  ENABLE ROW LEVEL SECURITY;

CREATE INDEX approval_requests_location_status_requested_idx ON public.approval_requests USING btree (location_id, status, requested_at DESC, id DESC);

CREATE INDEX approval_requests_requester_requested_idx ON public.approval_requests USING btree (location_id, requested_by_id, requested_at DESC);

CREATE TRIGGER approval_request_signal_realtime_v1
  AFTER INSERT OR DELETE OR UPDATE ON public.approval_requests
  FOR EACH ROW
  EXECUTE FUNCTION public.signal_approval_request_change_v1();

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."approval_requests" TO "service_role";

REVOKE ALL ON TABLE "public"."approval_requests" FROM "postgres";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."approval_requests" TO "postgres";

REVOKE ALL ON TABLE "public"."approval_requests" FROM "anon", "authenticated";
