; ModuleID = 'frtN.c'
; HAND-TRIMMED + HAND-NAMED-BLOCKS from clang-18 -O0 output (frtN_O0.ll) for
; BennettVM ingest. The C source is test/reference/frtN.c. Exact edits and
; rationale below; full provenance also in test/test_dyn_roundtrip.jl.
;
; EDIT 1 — VLA stack-management scaffolding removed (the extractor rejects it):
;   Removed from the verbatim clang-18 -O0 emission (frtN_O0.ll):
;     * `%3 = alloca ptr` (stacksave slot), `%4 = alloca i64` (VLA-size slot,
;       never read for the result), `store i64 %9, ptr %4`;
;     * the `%10 = call ptr @llvm.stacksave.p0()` / `store ptr %10, ptr %3` /
;       `%43 = load ptr, ptr %3` / `call void @llvm.stackrestore.p0(ptr %43)`
;       quadruple, and the two intrinsic `declare`s.
;   These are pure VLA *stack-pointer* save/restore scaffolding; none of the
;   removed values feed `ret` (the result data flow is %42 <- %6 <- reduction).
;   The extractor has no intrinsic handler for `llvm.stacksave.p0`
;   (Bennett-5oyt / U15), so the verbatim -O0 IR is rejected. Removing the
;   scaffolding is the minimal change that lets the genuine VLA semantics
;   (the dynamic `alloca i32, i64 %9`, the two loops, the indexed
;   stores/loads, the reduction) flow through. The dynamic VLA alloca itself
;   (`%11 = alloca i32, i64 %9`) is KEPT VERBATIM — it is exactly the
;   dynamic-N alloca BennettVM Case A must lower. The `%2 = alloca i32` spill
;   of the argument is KEPT (real scalar heap traffic, mirrors through_mem.ll).
;
; EDIT 2 — basic blocks given TEXTUAL names (a pure-cosmetic LLVM relabel):
;   clang -O0 emits NUMERICALLY-labelled blocks (`12:`, `16:`, ...) which have
;   no textual name; Bennett `extract_parsed_ir_from_ll` maps an unnamed block
;   to `Symbol("")` (module_walk.jl:168 `Symbol(LLVM.name(bb))`), collapsing
;   all blocks to one label and producing un-lowerable IR. Block names are
;   SEMANTICALLY INERT in LLVM (they do not affect execution), so naming each
;   block (entry, l1_cond, l1_body, l1_inc, l1_end, l2_cond, l2_body, l2_inc,
;   l2_end) is a faithful relabel, not a semantic change. SSA VALUE numbers are
;   unchanged from frtN_O0.ll; the `; preds` comments are dropped (comments are
;   inert). Verified well-formed by `opt-18 -passes=verify` (VERIFY OK).
source_filename = "frtN.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i32 @frtN(i32 noundef %0) #0 {
entry:
  %2 = alloca i32, align 4
  %5 = alloca i32, align 4
  %6 = alloca i32, align 4
  %7 = alloca i32, align 4
  store i32 %0, ptr %2, align 4
  %8 = load i32, ptr %2, align 4
  %9 = zext i32 %8 to i64
  %11 = alloca i32, i64 %9, align 16
  store i32 0, ptr %5, align 4
  br label %l1_cond

l1_cond:
  %13 = load i32, ptr %5, align 4
  %14 = load i32, ptr %2, align 4
  %15 = icmp slt i32 %13, %14
  br i1 %15, label %l1_body, label %l1_end

l1_body:
  %17 = load i32, ptr %5, align 4
  %18 = load i32, ptr %5, align 4
  %19 = mul nsw i32 %17, %18
  %20 = load i32, ptr %5, align 4
  %21 = sext i32 %20 to i64
  %22 = getelementptr inbounds i32, ptr %11, i64 %21
  store i32 %19, ptr %22, align 4
  br label %l1_inc

l1_inc:
  %24 = load i32, ptr %5, align 4
  %25 = add nsw i32 %24, 1
  store i32 %25, ptr %5, align 4
  br label %l1_cond, !llvm.loop !6

l1_end:
  store i32 0, ptr %6, align 4
  store i32 0, ptr %7, align 4
  br label %l2_cond

l2_cond:
  %28 = load i32, ptr %7, align 4
  %29 = load i32, ptr %2, align 4
  %30 = icmp slt i32 %28, %29
  br i1 %30, label %l2_body, label %l2_end

l2_body:
  %32 = load i32, ptr %7, align 4
  %33 = sext i32 %32 to i64
  %34 = getelementptr inbounds i32, ptr %11, i64 %33
  %35 = load i32, ptr %34, align 4
  %36 = load i32, ptr %6, align 4
  %37 = add nsw i32 %36, %35
  store i32 %37, ptr %6, align 4
  br label %l2_inc

l2_inc:
  %39 = load i32, ptr %7, align 4
  %40 = add nsw i32 %39, 1
  store i32 %40, ptr %7, align 4
  br label %l2_cond, !llvm.loop !8

l2_end:
  %42 = load i32, ptr %6, align 4
  ret i32 %42
}

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }

!llvm.module.flags = !{!0, !1, !2, !3, !4}
!llvm.ident = !{!5}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{i32 8, !"PIC Level", i32 2}
!2 = !{i32 7, !"PIE Level", i32 2}
!3 = !{i32 7, !"uwtable", i32 2}
!4 = !{i32 7, !"frame-pointer", i32 2}
!5 = !{!"Ubuntu clang version 18.1.3 (1ubuntu1)"}
!6 = distinct !{!6, !7}
!7 = !{!"llvm.loop.mustprogress"}
!8 = distinct !{!8, !7}
