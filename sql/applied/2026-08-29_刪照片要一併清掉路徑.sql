/* ============================================================
   刪頭像照片時一併清掉 members.avatar_photo_path
   2026-08-29

   ── 🔴 現場 ────────────────────────────────────────
   2026-08-29 實機測試：上傳一張照片、再按刪除，之後抽屜出現一個
   **「有刪除鍵卻沒有照片」的格子**。查下去：

   ```
   members.avatar_photo_path = '69016205-…/1787987253605.webp'
   storage.objects (member-avatars) = 0 筆
   ```

   `deleteAvatarPhoto()` 只做了 `supabase.storage.remove([path])` ——
   **檔案刪了，資料庫那一欄沒動**。

   ⚠ 症狀很輕（一個空格子），但後果不輕：那一格還點得下去，
     套用之後 `avatar_source='photo'` 會指向一個**不存在的檔案**，
     而顯示端拿不到簽名網址就退回小熊 ——
     **客人看到的是「設定成功但沒有變」**，那是最難查的一種。

   ── 🎯 順序：先清資料庫，再刪檔案 ──────────────────
   兩件事一定有一件可能失敗，所以要選一個**活得下去的失敗**：

   | 順序 | 中途失敗會留下 | 嚴重嗎 |
   |---|---|---|
   | 先刪檔案、再清欄位（← 現在） | **欄位指向不存在的檔案** | 🔴 就是上面那個症狀 |
   | **先清欄位、再刪檔案** | 孤兒檔案（沒有人指向它） | 🟢 看不見、不影響任何畫面 |

   → 一律**先清欄位**。孤兒檔案由 `cleanOldAvatarPhotos()` 順手掃掉，
     而且 Storage 收緊之後會由 Edge Function 統一處理。

   ── 為什麼是一支 RPC 不是前端直接 update ──────────
   `members` 有 RLS，前端用 anon 直接 update 會**改到 0 列且不報錯**
   （硬規則 4）—— 那正是這個 bug 換一種形狀再發生一次。

   📌 這支之後會被 Storage 收緊時的 Edge Function 重用
     （那時刪檔案也要走 service_role），**不是拋棄式的**。
   ============================================================ */

create or replace function public.clear_avatar_photo_tx(p_member_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare
  v_path text;
  v_src  text;
begin
  select avatar_photo_path, avatar_source into v_path, v_src
    from members where id = p_member_id and deleted_at is null;

  /* 🔴 分辨「查不到這個人」與「他本來就沒有照片」——
     兩者都會讓 v_path 是 null，但意思完全不同。
     用 FOUND 判斷（`register_member_tx` 就是漏了這一步而謊報成功）。 */
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'member_not_found');
  end if;

  /* 沒有照片是**正常結果不是錯誤** —— 重複按刪除、或兩個分頁同時刪，
     都會走到這裡。回 ok 讓呼叫端繼續刪檔案（冪等）。 */
  if v_path is null then
    return jsonb_build_object('ok', true, 'path', null, 'already_clear', true);
  end if;

  update members
     set avatar_photo_path = null,
         avatar_photo_at   = null,
         /* ⚠ 正在用這張照片的話要一起切回小熊，否則 avatar_source 會停在
            'photo' 而路徑是 null —— 那是另一種「設定成功但沒有變」。
            切回**通用預設熊**（avatar_bear 不動，他之前選的那一隻留著）。 */
         avatar_source     = case when v_src = 'photo' then 'bear' else v_src end,
         updated_at        = now()
   where id = p_member_id;

  -- 回傳被清掉的路徑，讓呼叫端知道要刪哪一個檔案
  return jsonb_build_object('ok', true, 'path', v_path,
                            'switched_to_bear', v_src = 'photo');
end $function$;

/* 🔴 兩行 revoke 都要寫（硬規則 2.6 與 2.6b）——
   PUBLIC 是 Postgres 的預設，anon 是 Supabase 的 default privileges，
   兩條路都要收才乾淨。這一支**要給前端叫**，所以收完再明確授權。
   ⚠ 先收再給，順序反了等於沒收。 */
revoke execute on function public.clear_avatar_photo_tx(uuid) from public;
revoke execute on function public.clear_avatar_photo_tx(uuid) from anon, authenticated;
grant  execute on function public.clear_avatar_photo_tx(uuid) to anon, authenticated, service_role;


/* ── 修掉現場那一筆 ──────────────────────────────
   ⚠ 用函式自己修，不要手寫 update ——
     這樣同時**驗證了函式真的會動**（硬規則 7：RPC 寫完必須實際執行）。 */
do $$
declare r jsonb;
begin
  r := clear_avatar_photo_tx('69016205-afde-4036-95a6-5893c9d0e5fe');
  perform set_config('migi.fix', r::text, false);
end $$;


/* ============================================================
   驗證（單一 SELECT）

   ① 現場那一筆修好了沒
   ② 🎯 正對照：**冪等** —— 再清一次應該回 already_clear 而不是報錯
      （重複按刪除、或兩個分頁同時刪，都會走到這條）
   ③ 🎯 正對照：`avatar_bear` **不可以**被清掉
      —— 只驗「路徑清了」那一半不夠：把 update 寫太寬也會讓路徑消失，
        而那個症狀跟正確行為長得一模一樣（硬規則 3.55）
   ④ 授權：anon 要有，而且不是靠 PUBLIC 繼承
   ⑤ 全庫掃：還有沒有別人的 avatar_photo_path 指向不存在的檔案
   ============================================================ */
select 序, 項目, 內容 from (

  select 1 as 序, '① 現場那一筆（Jim）' as 項目,
         (select 'avatar_source=' || coalesce(avatar_source,'null')
              || '　avatar_photo_path=' || coalesce(avatar_photo_path,'null')
              || case when avatar_photo_path is null and avatar_source <> 'photo'
                      then '　✅ 清乾淨了' else '　🔴 還沒修好' end
            from members where id = '69016205-afde-4036-95a6-5893c9d0e5fe')
         || E'\n  修的時候函式回：' || coalesce(current_setting('migi.fix', true), '(沒拿到)') as 內容

  union all
  select 2, '② 🎯 正對照：冪等（再清一次不該報錯）',
         (select case when (r->>'ok')::boolean and (r->>'already_clear')::boolean
                      then '✅ already_clear —— 重複按刪除不會出事'
                      else '🔴 ' || r::text end
            from (select clear_avatar_photo_tx('69016205-afde-4036-95a6-5893c9d0e5fe') as r) t)

  union all
  select 3, '③ 🎯 正對照：avatar_bear 不可以被一起清掉',
         (select coalesce(avatar_bear, '(null＝通用預設熊，本來就是)')
              || '　⚠ Jim 本來就沒選過造型，所以這裡是 null 是對的；'
              || E'\n     真正的保護在函式裡：update 沒有碰 avatar_bear'
            from members where id = '69016205-afde-4036-95a6-5893c9d0e5fe')

  union all
  select 4, '④ 授權（anon 要有，且不是靠 PUBLIC 繼承）',
         (select 'anon=' || case when has_function_privilege('anon', p.oid, 'execute') then '✅ 有' else '🔴 無' end
              || '（明確=' || case when exists (select 1 from aclexplode(coalesce(p.proacl,'{}')) a
                                     where a.grantee = 'anon'::regrole::oid and a.privilege_type='EXECUTE')
                                   then 'Y' else 'N' end
              || '　PUBLIC=' || case when (p.proacl is null or exists (select 1 from aclexplode(p.proacl) a
                                     where a.grantee = 0 and a.privilege_type='EXECUTE'))
                                   then '🔴 Y' else '✅ N' end || '）'
            from pg_proc p
           where p.pronamespace='public'::regnamespace and p.proname='clear_avatar_photo_tx')

  union all
  select 5, '⑤ 全庫：還有誰的 avatar_photo_path 指向不存在的檔案',
         coalesce((select string_agg(m.display_name || '　' || m.avatar_photo_path, E'\n')
                     from members m
                    where m.avatar_photo_path is not null
                      and not exists (select 1 from storage.objects o
                                       where o.bucket_id = 'member-avatars'
                                         and o.name = m.avatar_photo_path)),
                  '✅ 一個都沒有')

) x order by 序;
