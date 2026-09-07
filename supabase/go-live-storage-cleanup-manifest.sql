-- ADHUNIK ERP GO-LIVE STORAGE CLEANUP MANIFEST
-- READ-ONLY. Run before the database reset and export the result.
-- This file lists objects only; it does not remove or modify them.

select manifest.bucket,
       manifest.object_path,
       manifest.related_module,
       manifest.related_record,
       manifest.reason_for_removal,
       manifest.created_at,
       manifest.size_bytes
from (
  select o.bucket_id as bucket,
         o.name as object_path,
         'CRM Inquiry'::text as related_module,
         i.inquiry_number as related_record,
         'Attachment belongs to an approved pre-go-live inquiry'::text as reason_for_removal,
         o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint as size_bytes
  from storage.objects o
  join public.inquiries i on split_part(o.name, '/', 1) = i.id::text
  where o.bucket_id = 'crm-inquiry-attachments'

  union all

  select o.bucket_id, o.name, 'CRM Order', r.order_number,
         'Attachment belongs to an approved pre-go-live order', o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o
  join public.orders r on split_part(o.name, '/', 1) = r.id::text
  where o.bucket_id = 'crm-order-attachments'

  union all

  select o.bucket_id, o.name, 'Proforma Invoice', p.pi_number,
         'Generated document belongs to an approved pre-go-live PI', o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o
  join public.proforma_invoices p on split_part(o.name, '/', 1) = p.id::text
  where o.bucket_id = 'pi-documents'

  union all

  select o.bucket_id, o.name, 'Sales Payment Receipt', r.id::text,
         'Payment proof belongs to an approved pre-go-live receipt', o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o
  join public.sales_payment_receipts r
    on o.name = r.proof_storage_path
    or split_part(o.name, '/', 3) = r.id::text
  where o.bucket_id = 'sales-payment-proofs'

  union all

  select o.bucket_id, o.name, 'Item Master', i.item_code,
         'Image belongs to an explicitly approved test item', o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o
  join public.items i
    on o.name = i.image_path
    or split_part(o.name, '/', 1) = i.id::text
  where o.bucket_id = 'item-images'
    and i.id in (
      'f31df934-4e55-47ba-ab69-b1d42627ed89'::uuid,
      '3738f482-7292-4a06-996d-2f13c03d6c37'::uuid
    )

  union all

  select o.bucket_id, o.name, 'Dispatch', d.dispatch_number,
         'Document belongs to an approved pre-go-live dispatch', o.created_at,
         nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o
  join public.dispatches d on split_part(o.name, '/', 1) = d.id::text
  where o.bucket_id = 'dispatch-documents'
) manifest
order by manifest.bucket, manifest.object_path;

select bucket, count(*) as approved_object_count, coalesce(sum(size_bytes), 0) as total_bytes
from (
  select o.bucket_id as bucket, nullif(o.metadata ->> 'size', '')::bigint as size_bytes
  from storage.objects o join public.inquiries i on split_part(o.name, '/', 1) = i.id::text
  where o.bucket_id = 'crm-inquiry-attachments'
  union all
  select o.bucket_id, nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o join public.orders r on split_part(o.name, '/', 1) = r.id::text
  where o.bucket_id = 'crm-order-attachments'
  union all
  select o.bucket_id, nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o join public.proforma_invoices p on split_part(o.name, '/', 1) = p.id::text
  where o.bucket_id = 'pi-documents'
  union all
  select o.bucket_id, nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o join public.sales_payment_receipts r
    on o.name = r.proof_storage_path or split_part(o.name, '/', 3) = r.id::text
  where o.bucket_id = 'sales-payment-proofs'
  union all
  select o.bucket_id, nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o join public.items i
    on o.name = i.image_path or split_part(o.name, '/', 1) = i.id::text
  where o.bucket_id = 'item-images'
    and i.id in ('f31df934-4e55-47ba-ab69-b1d42627ed89'::uuid, '3738f482-7292-4a06-996d-2f13c03d6c37'::uuid)
  union all
  select o.bucket_id, nullif(o.metadata ->> 'size', '')::bigint
  from storage.objects o join public.dispatches d on split_part(o.name, '/', 1) = d.id::text
  where o.bucket_id = 'dispatch-documents'
) approved
group by bucket
order by bucket;
