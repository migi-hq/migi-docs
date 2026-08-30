/* ============================================================
   `get_my_profile_tx` 回完整手機（不再遮罩）　2026-08-30 · MIGI

   ── 為什麼改 ────────────────────────────────────────
   使用者：「`0910***` 有顯示就不要隱藏，不然不知道自己是哪個手機。」
   遮罩露 4 頭 3 尾，中間三碼藏起來 —— 對「這是我的哪一支？」
   這個問題**答不完整**，而那正是這一列存在的唯一用途。

   ── ⚠ 代價（明講，不要假裝沒有）────────────────────
   `get_my_profile_tx` 是 **DEFINER ＋ anon**，而會員身分是
   **前端送的 `p_member_id`**（待辦 14 的 JWT 還沒做完）。
   ⇒ 知道某人的 member uuid，就查得到他的**完整手機號碼**。

   📌 但今天的實際風險比先前小很多：
   · 2026-08-30 已堵掉 `register_member_tx` 交出 member_id 的路徑
     （之前只要知道一支手機號就拿得到 uuid —— **反過來的洞更嚴重**）
   · 這支函式本來就已經回傳**生日**與**性別**了 ——
     說「手機不能回」而生日可以，本身就不一致
   ⚠ 手機仍然是**可以聯絡到人**的那一類，性質跟生日不同。
     → 待辦 14 上線時這支要改成從 `auth.uid()` 取身分、拿掉 `p_member_id`，
       那時這個代價才真的歸零。**在那之前它是一個已知的、被接受的取捨。**

   ── 改什麼 ──────────────────────────────────────────
   `'phone_masked', <遮罩>`  →  `'phone', m.phone`
   ⚠ **不要兩個都回。** 一個名字一個意思（待辦 35 那個病的第 N 次）——
     兩個都在的話，下一個人不知道該讀哪一個，而且一定會有人讀到舊的。
   ✅ `phone_verified` 保留：它跟「有沒有號碼」是兩件事
     （欄位有值只代表有人填過，不代表那支手機是他的）。

   ⚠ `get_member_by_line_tx`（whoami）**維持遮罩，刻意不動** ——
     它回答的是「這個 LINE 是誰」，而畫面不顯示那個值。
     用不到的資料不要多回一份（同 2026-08-26 只補 birthday 不補其餘的決定）。

   ✅ 簽名沒變 → `CREATE OR REPLACE`，不用 DROP、不會掉 GRANT。
   ============================================================ */

create or replace function public.get_my_profile_tx(p_org_id uuid, p_member_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb;
begin
  select jsonb_build_object(
    'id', m.id, 'nickname', m.display_name,
    /* ★ 2026-08-30：改回完整號碼（原本是 left(4)||'***'||right(3)）。
       遮罩答不出「這是我的哪一支」，而那是這一列唯一的用途。 */
    'phone', m.phone,
    'phone_verified', (m.phone_verified_at is not null),
    'rank', m.rank, 'title', m.title,
    'likes_count', m.likes_count, 'avatar_url', m.avatar_url,
    -- ★ 2026-08-29：頭像有三個來源，只回 avatar_url 的話
    --   個人檔案永遠畫段位熊（而且不會報錯）。
    'avatar_source', m.avatar_source,
    'avatar_photo_path', m.avatar_photo_path,
    'avatar_bear', m.avatar_bear,
    'tier', m.tier,
    'app_state', coalesce(s.bear, '{}'::jsonb),
    'titles_unlocked', coalesce(s.titles, '[]'::jsonb),
    'about', m.about,
    'sched', m.sched,
    'style', m.style,
    -- ★ 2026-08-26 新增。生日招待是已承諾的權益，
    --   而在這之前前端讀不到現值，填完看起來像沒存成功。
    'birthday', m.birthday, 'gender', m.gender,
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

-- ── 驗證 ──────────────────────────────────────────────
/* 🔴 **正對照在同一列**（硬規則 3.55）：
   只驗「有 phone」的話，萬一我把整個 jsonb 打壞、其他欄位全不見了，
   看到的畫面一模一樣。所以一起檢查幾個原本就該在的鍵。
   ⚠ 也明確檢查 `phone_masked` **已經消失** ——
     兩個並存才是真正的壞結果（下一個人不知道該讀哪一個）。 */
select
  case when v ? 'phone' and (v->>'phone') = m.phone
       then '✅ 完整號碼回來了' else '🔴 phone 不對' end                       as 一_完整號碼,
  case when not (v ? 'phone_masked')
       then '✅ 遮罩版已移除' else '🔴 兩個並存 —— 沒有人知道該讀哪一個' end   as 二_舊鍵,
  case when (v->>'phone_verified')::boolean = (m.phone_verified_at is not null)
       then '✅ 驗證旗標仍正確' else '🔴 phone_verified 錯了' end              as 三_驗證旗標,
  case when v ? 'birthday' and v ? 'avatar_bear' and v ? 'home_store_name'
            and v ? 'titles_unlocked' and v ? 'baby_tile'
       then '✅ 其餘欄位都還在' else '🔴 有欄位掉了 —— 整支被我改壞' end       as 四_正對照,
  v->>'phone' as 實際值
from members m,
     lateral (select public.get_my_profile_tx(m.org_id, m.id) as v) g
where m.phone = '0910768736' and m.deleted_at is null;
