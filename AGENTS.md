# AGENTS.md — Rule of Agents & AI Development Workflow

This repository strictly enforces a **Task-by-Task AI Development Workflow**. Every AI agent working on **Center Hub** must follow the 7-step loop below for each individual task without skipping steps or combining multiple tasks without explicit user approval.

---

## 🔄 7-Step AI Development Workflow (Rule of Agents)

ต้องทำงานแบบ **Task-by-Task** ตามลำดับ 7 ขั้นตอนดังนี้เสมอ:

1. **Plan (วางแผน)**
   - AI วิเคราะห์ Requirements ของ Task ปัจจุบัน และเสนอแผนการทำงานอย่างชัดเจน (เป้าหมาย, ไฟล์ที่จะสร้าง/แก้ไข, และวิธีการทดสอบ)
2. **Approve (อนุมัติแผน)**
   - รอให้ผู้ใช้งานตรวจสอบและอนุมัติแผนก่อนเริ่มเขียนโค้ด (ห้ามข้ามไปเขียนโค้ดก่อนได้รับอนุมัติ)
3. **Implement (ลงมือเขียนโค้ด)**
   - AI เขียนโค้ดเฉพาะในขอบเขตของ Task ที่ได้รับอนุมัติเท่านั้น
4. **Test (ทดสอบ)**
   - AI รันการทดสอบอัตโนมัติ (Unit Tests, Linter, Type Check, หรือ Validation Script) และตรวจสอบผลลัพธ์จริง
5. **Fix (แก้ไขและทดสอบซ้ำ)**
   - หากพบข้อผิดพลาดจากการทดสอบ AI ต้องแก้ไขปัญหาและรันทดสอบซ้ำจนกว่าจะผ่านทั้งหมด
6. **Review (สรุปงานและประเมินความเสี่ยง)**
   - AI สรุปไฟล์ที่สร้าง/แก้ไข ผลการทดสอบ และความเสี่ยงหรือข้อควรระวัง (Risks & Edge Cases) ให้ผู้ใช้งานทราบ
7. **Checkpoint Approval (อนุมัติจบ Task)**
   - รอให้ผู้ใช้งานอนุมัติผลงานของ Task ปัจจุบันก่อน จึงจะเริ่มนำเสนอ **Step 1: Plan** ของ Task ถัดไปได้

---

## 🏗️ Project Architecture & Standards (Center Hub)

- **Repository Layout**:
  - `frontend/` — Next.js (App Router, TypeScript, Tailwind CSS)
  - `backend/` — FastAPI + Celery + Redis (Python 3.12+)
  - `supabase/` — PostgreSQL Schema Migrations, RLS Policies, Storage Buckets
  - `docker-compose.yml` — Container orchestration for local development and production
- **Target Platforms**: YouTube, TikTok, Instagram Reels, Facebook Reels
- **Smart Storage Architecture**:
  - `permanent-assets` bucket: Permanent storage for lightweight assets (thumbnails, avatars).
  - `ephemeral-videos` bucket: Temporary staging for raw video files. Automatically deleted upon successful multi-platform publishing (with a 24-hour Celery Beat cleanup fallback).
- **UI/UX Design Vibe**:
  - Inspired by **Linear & Stripe**: Minimal, calm, light-theme first (`#FAFAFA` canvas, `#FFFFFF` surfaces, subtle borders, `Inter` typography, tabular numerals for analytics).
