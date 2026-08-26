/* ============================================================
   get_my_profile_tx 補回傳 birthday
   2026-08-26 · 簽名不變 → CREATE OR REPLACE，不會丟 GRANT

   ✅ 已執行並驗證通過（2026-08-26）
      版本數 1／DEFINER／anon ✅／birthday 鍵已回傳（值 null，還沒人填）／
      **舊的 16 個鍵一個都沒掉**／**內部欄位沒被順手加進來**。

   ── 為什麼要補 ──────────────────────────────────────
   `set_my_birthday_tx` 已上線（會員填得進去了），但這支不回傳 birthday
   → **前端讀不到現值，只能永遠顯示空白**
   → 使用者會以為沒存成功而重填。

   ── ⚠ 只補 birthday，不順手多加 ────────────────────────
   `members` 上還有這些沒回傳的欄位：
     `gender` / `occupation` / `district` / `acquisition_source` / `phone`
   **刻意不加**：
     · gender / occupation / district / acquisition_source 是**註冊與行銷用的
       內部欄位**，不是會員自己要看的東西。回傳它們等於把 CRM 資料
       送到客戶端，而客戶端沒有任何地方要用。
     · phone 是會員自己的沒錯，但 App 目前沒有顯示手機的地方 ——
       多回傳一個 PII 欄位卻沒人讀，是白白擴大暴露面。
   → **需要才加**，不要因為「順手」。

   ── 與線上版的唯一差異 ──────────────────────────────
   jsonb_build_object 多一個鍵：'birthday', m.birthday
   其餘逐字保留（硬規則 3：改既有函式一律先撈線上版，這份是照撈回來的改的）。
   ============================================================ */

create or replace function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v jsonb;
begin
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb),
    'about', m.about,
    'sched', m.sched,
    'style', m.style,
    -- ★ 2026-08-26 新增。生日招待是已承諾的權益，
    --   而在這之前前端讀不到現值，填完看起來像沒存成功。
    'birthday', m.birthday,
    'see_score', m.see_score,
    'baby_tile', m.baby_tile,
    'home_store_id', m.home_store_id,
    'home_store_name', st.name
  ) into v
  from members m
  left join member_app_state s on s.member_id = m.id
  left join stores st on st.id = m.home_store_id
  where m.id = p_member_id and m.org_id = p_org_id and m.deleted_at is null;
  if v is null then raise exception '會員不存在'; end if;
  return v;
end $function$;


/* ============================================================
   驗證段（單一 SELECT）
   ⚠ 硬規則 7：真的呼叫一次，拿真實會員的資料看。
   ============================================================ */

with probe as (
  select m.id, m.org_id from members m
   where m.deleted_at is null order by m.created_at limit 1
),
r as (select get_my_profile_tx(p.org_id, p.id) as j from probe p)
select 序, 項目, 結果 from (

  select 0 as 序, '① 版本數與權限' as 項目,
         (case when count(*) = 1 then '✅ 1 個（簽名沒變）'
               else '🔴 ' || count(*)::text || ' 個' end)
         || '　' || (case when bool_and(p.prosecdef) then 'DEFINER' else '🔴 INVOKER' end)
         || '　anon ' || (case when bool_and(has_function_privilege('anon', p.oid, 'EXECUTE'))
                               then '✅' else '🔴 沒有' end) as 結果
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and p.proname = 'get_my_profile_tx'

  union all
  select 0, '② birthday 這個鍵在不在',
         coalesce((select case when j ? 'birthday' then '✅ 有（值：' ||
                                    coalesce(j ->> 'birthday', 'null（還沒填）') || '）'
                               else '🔴 沒有' end from r), '🔴 回傳 null')

  union all
  /* ③ 舊的鍵一個都不能少 —— 少一個前端就會拿到 undefined 而不報錯。 */
  select 0, '③ 舊的鍵有沒有掉',
         coalesce((select case when count(*) = 0 then '✅ 全部都在'
                               else '🔴 少了：' || string_agg(k, '、') end
                     from (values ('id'),('nickname'),('rank'),('title'),
                                  ('likes_count'),('avatar_url'),('tier'),
                                  ('app_state'),('titles_unlocked'),('about'),
                                  ('sched'),('style'),('see_score'),('baby_tile'),
                                  ('home_store_id'),('home_store_name')) v(k)
                    where not (select j from r) ? k), '✅ 全部都在')

  union all
  /* ④ 刻意沒加的那些，確認真的沒混進來 ——
        「順手多加」是最容易發生的擴大暴露面。 */
  select 1, '④ 內部欄位沒被順手加進來',
         coalesce((select case when count(*) = 0 then '✅ 沒有'
                               else '🔴 混進來了：' || string_agg(k, '、') end
                     from (values ('gender'),('occupation'),('district'),
                                  ('acquisition_source'),('phone'),
                                  ('is_test'),('primary_staff_id'),('lifecycle')) v(k)
                    where (select j from r) ? k), '✅ 沒有')

) x order by 序, 項目;
