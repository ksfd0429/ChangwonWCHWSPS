-- Para Trap 비공식 훈련 단가: 5 EUR/round → 10 USD/round 정정. 멱등.
-- 1) 단가 설정(oc_settings.pricing)의 training 값을 10으로.
-- 2) 승인 전(pending) 인보이스 초안에 이미 박혀 있는 훈련 항목을 10 USD/round · USD 통화로 재작성.
--    (승인/발행된 인보이스는 건드리지 않는다.)

update oc_settings
   set value = ((value::jsonb) || '{"training":10}'::jsonb)::text
 where key = 'pricing';

with fixed as (
  select v.id,
         jsonb_agg(
           case when it->>'d' ilike '%Unofficial Training%' then
             jsonb_build_object(
               'sec','Miscellaneous',
               'd','Unofficial Training Fee (Para Trap only)',
               's','(per round · payable on site)',
               'q', coalesce(nullif(regexp_replace(it->>'q','[^0-9].*$',''),''),'0') || ' Round(s)',
               'm','',
               'p','* 10 USD =',
               't', coalesce(nullif(regexp_replace(it->>'q','[^0-9].*$',''),''),'0')::int * 10
             )
           else it end
           order by x.ord
         ) as items
    from invoices v,
         lateral jsonb_array_elements(v.items::jsonb) with ordinality x(it, ord)
   where v.items::text ilike '%Unofficial Training%'
     and v.status <> 'approved'
   group by v.id
)
update invoices v
   set items = f.items
  from fixed f
 where v.id = f.id;

-- 검증
select 'pricing' src, null::bigint id, null::text country, value txt
  from oc_settings where key='pricing'
union all
select 'invoice', v.id, v.country,
       (it->>'q')||' / '||(it->>'p')||' / t='||(it->>'t')||' / cur='||coalesce(it->>'cur','(none)')
  from invoices v, lateral jsonb_array_elements(v.items::jsonb) it
 where it->>'d' ilike '%Unofficial Training%'
 order by 2 nulls first;
