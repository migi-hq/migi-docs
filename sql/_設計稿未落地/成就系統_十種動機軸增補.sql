-- 【成就系統・執行狀態待確認】motivation 擴充為十種的增補 SQL，對應企劃 v2.3。
-- ============================================================
-- MIGI 成就系統 · motivation 擴充為「10 種」
-- 七原有 + 新增 consumption(消費回饋) / habit(養成習慣) / expression(自我表達) / story(劇情驚喜)
-- 接在 成就系統_achievements_schema_RPC.sql 之後部署(addendum,不改產生檔)
-- ============================================================

alter table achievements drop constraint if exists achievements_motivation_check;
alter table achievements drop constraint if exists chk_ach_motivation;

do $$ begin
  alter table achievements
    add constraint chk_ach_motivation
    check (motivation in (
      'completion','competition','social','exploration','collection','prestige',
      'consumption',   -- 消費回饋(點飲料/餐點/續杯/兌換)
      'habit',         -- 養成習慣(連續報到/月月到店/固定局;凡 struct=streak 一律此類)
      'expression',    -- 自我表達(設定稱號/頭像框/個人頁裝飾)
      'story'          -- 劇情驚喜(局勢轉折的戲劇性)
    ));
exception when duplicate_object then null; end $$;
