-- 【待執行】revenue_type 階段 C-3：清掉雙軌的發射端，並修好一道失效的擋牆
-- ============================================================
-- C-2 的驗證回傳「仍提到 kind 的函式」有七支，而我預期只有三支
-- （create_invoice_draft_tx / get_wallet_tx / void_invoice_tx，
--   它們的 kind 是 invoices.kind 與 coupons.kind，本來就不該動）。
-- 多出來的四支是階段 A 刻意留下的**雙軌發射端** —— 我寫驗證時只想到讀取端。
--
-- 🔴 追下去發現一個真的洞（本檔最重要的一段）
--   join_session_tx 擋「前端自己送場地費」的那道牆是：
--       where it ->> 'kind' = 'fee'
--   POS 階段 B 之後送的是 revenue_type，`it->>'kind'` 永遠是 null ——
--   **那道牆從階段 B 上線起就沒有在擋任何東西。**
--   目前沒出事只是因為 POS 自己的 doPay 也擋，
--   但那道後端牆存在的理由正是「不能信任前端」。
--   如果前端送一筆場地費，後端會照收，而 join_session_tx 自己也算了一份
--   —— 那是重複收費，且畫面上完全看不出來。
--
--   → 這是「改值失敗是無聲的」的教科書案例：
--     沒有任何錯誤、沒有任何測試會紅、金額在一般路徑上完全正確。
--     只有在有人刻意送壞資料時才會現形，而那正是它要防的情況。
--
-- 【本檔改動】
--   ① list_products_tx   不再回傳 kind
--   ② list_daypass_tx    不再回傳 kind
--   ③ join_session_tx    組品項不再寫 kind；**擋牆改看 revenue_type**
--   ④ checkout_tx        移除 kind 的相容換算
--
-- 【為什麼現在可以拿掉 checkout_tx 的相容】
--   ①②③ 一旦跑完，舊 bundle 本來就活不下去（它讀 p.kind 會拿到 undefined）。
--   保留 checkout_tx 對 kind 的容忍只會讓「壞掉的方式」變得比較安靜，
--   不會讓它不壞。POS 有開機版本看門狗，重新整理即為新版。
--   → 跑完這支請在 POS 按一次重新整理，不要等快取自己過期。
-- ============================================================

-- ① list_products_tx
create or replace function public.list_products_tx(p_org_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'sku', sku, 'name', name, 'category', category,
      'unit_price', unit_price,
      'revenue_type', revenue_type
    ) order by category, sku)
    from products
    where org_id = p_org_id and is_active and coalesce(is_available, true)
      and deleted_at is null
      and sku not like 'SVC-TBL-%'   -- 檯費不列入加購清單，避免店員手動點錯
  ), '[]'::jsonb);
end $function$;

-- ② list_daypass_tx
create or replace function public.list_daypass_tx(p_org_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           p.id,
           'sku',          p.sku,
           'name',         p.name,
           'category',     p.category,
           'unit_price',   p.unit_price,
           'revenue_type', 'venue_fee')), '[]'::jsonb)
    from public.products p
   where p.org_id = p_org_id
     and p.sku = 'SVC-TBL-DAY'
     and p.is_active
     and p.deleted_at is null;
$$;

comment on function public.list_daypass_tx(uuid) is
  '當日暢打商品（SVC-TBL-DAY）。list_products_tx 不回 service 類，POS 要在「檯費」分頁賣它得單獨撈。';

grant execute on function public.list_daypass_tx(uuid) to anon, authenticated;

-- ③ join_session_tx：組品項不再寫 kind、擋牆改看 revenue_type
do $$
declare v_old text; v_new text; v_mid text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'join_session_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'join_session_tx 不存在'; end if;

  -- ③-a 自己組的檯費品項：拿掉 kind
  --     這串是階段 A 寫進去的，字面固定
  v_mid := replace(v_old,
    $src$'kind', 'fee', 'revenue_type', 'venue_fee',$src$,
    $dst$'revenue_type', 'venue_fee',$dst$);
  if v_mid = v_old then
    raise exception '找不到組品項的錨點 —— 階段 A 是否跑過？';
  end if;

  -- ③-b 擋牆：前端送來的品項改看 revenue_type
  --     空白由人手排，用 regexp 不用字面比對
  v_new := regexp_replace(v_mid,
    $re$it ->> 'kind'\s*=\s*'fee'$re$,
    $rp$it ->> 'revenue_type' = 'venue_fee'$rp$);
  if v_new = v_mid then
    raise exception '找不到擋牆的錨點 —— 先撈 pg_get_functiondef 確認';
  end if;

  -- 兩處都改完之後，這支函式不該再出現 kind
  if v_new ~ '\ykind\y' then
    raise exception 'join_session_tx 仍有 kind 殘留，不要盲目套用';
  end if;

  execute v_new;
end $$;

-- ④ checkout_tx：移除 kind 的相容換算
do $$
declare v_old text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_old
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'checkout_tx' and p.prokind = 'f';
  if v_old is null then raise exception 'checkout_tx 不存在'; end if;

  v_new := replace(v_old,
    $src$            coalesce(it->>'revenue_type',
                     case it->>'kind' when 'fee'   then 'venue_fee'
                                      when 'goods' then 'retail'
                                      else it->>'kind' end),$src$,
    $dst$            it->>'revenue_type',$dst$);

  if v_new = v_old then
    raise exception 'checkout_tx 找不到錨點 —— C-1 是否跑過？';
  end if;

  execute v_new;
end $$;

-- ============================================================
-- 驗證（單一 SELECT）
--   第一欄現在應該**只剩三支**：create_invoice_draft_tx / get_wallet_tx /
--   void_invoice_tx —— 它們的 kind 是 invoices.kind 與 coupons.kind。
--   第二欄是那道擋牆的現況，必須 true。
--   第三欄確認四支發射端都乾淨了。
-- ============================================================
with fns as (
  select p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
)
select
  (select jsonb_agg(proname order by proname)
     from fns where def ~ '\ykind\y')                                     as 仍提到kind的函式,
  (select bool_or(def like '%it ->> ''revenue_type'' = ''venue_fee''%')
     from fns where proname = 'join_session_tx')                          as 擋牆已改看收入桶,
  (select count(*) = 0 from fns
    where proname in ('checkout_tx', 'join_session_tx',
                      'list_products_tx', 'list_daypass_tx')
      and def ~ '\ykind\y')                                               as 四支發射端已清乾淨,
  (select jsonb_object_agg(revenue_type, n)
     from (select revenue_type, count(*) as n from public.order_items
            group by revenue_type) t)                                     as 收入桶分布;
