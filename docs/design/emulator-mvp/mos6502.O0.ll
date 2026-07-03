; ModuleID = 'mos6502.c'
source_filename = "mos6502.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i64 @mos6502(i64 noundef %n) #0 {
entry:
  %n.addr = alloca i64, align 8
  %mem = alloca ptr, align 8
  %A = alloca i64, align 8
  %pc = alloca i64, align 8
  %Z = alloca i64, align 8
  %running = alloca i64, align 8
  %budget = alloca i64, align 8
  %op = alloca i64, align 8
  %a = alloca i64, align 8
  %a51 = alloca i64, align 8
  %a74 = alloca i64, align 8
  %a89 = alloca i64, align 8
  %rel = alloca i64, align 8
  store i64 %n, ptr %n.addr, align 8
  %call = call noalias ptr @calloc(i64 noundef 64, i64 noundef 1) #3
  store ptr %call, ptr %mem, align 8
  %0 = load ptr, ptr %mem, align 8
  %arrayidx = getelementptr inbounds i8, ptr %0, i64 0
  store i8 -87, ptr %arrayidx, align 1
  %1 = load ptr, ptr %mem, align 8
  %arrayidx1 = getelementptr inbounds i8, ptr %1, i64 1
  store i8 0, ptr %arrayidx1, align 1
  %2 = load ptr, ptr %mem, align 8
  %arrayidx2 = getelementptr inbounds i8, ptr %2, i64 2
  store i8 -123, ptr %arrayidx2, align 1
  %3 = load ptr, ptr %mem, align 8
  %arrayidx3 = getelementptr inbounds i8, ptr %3, i64 3
  store i8 34, ptr %arrayidx3, align 1
  %4 = load ptr, ptr %mem, align 8
  %arrayidx4 = getelementptr inbounds i8, ptr %4, i64 4
  store i8 -87, ptr %arrayidx4, align 1
  %5 = load ptr, ptr %mem, align 8
  %arrayidx5 = getelementptr inbounds i8, ptr %5, i64 5
  store i8 0, ptr %arrayidx5, align 1
  %6 = load ptr, ptr %mem, align 8
  %arrayidx6 = getelementptr inbounds i8, ptr %6, i64 6
  store i8 -123, ptr %arrayidx6, align 1
  %7 = load ptr, ptr %mem, align 8
  %arrayidx7 = getelementptr inbounds i8, ptr %7, i64 7
  store i8 33, ptr %arrayidx7, align 1
  %8 = load ptr, ptr %mem, align 8
  %arrayidx8 = getelementptr inbounds i8, ptr %8, i64 8
  store i8 -91, ptr %arrayidx8, align 1
  %9 = load ptr, ptr %mem, align 8
  %arrayidx9 = getelementptr inbounds i8, ptr %9, i64 9
  store i8 34, ptr %arrayidx9, align 1
  %10 = load ptr, ptr %mem, align 8
  %arrayidx10 = getelementptr inbounds i8, ptr %10, i64 10
  store i8 105, ptr %arrayidx10, align 1
  %11 = load ptr, ptr %mem, align 8
  %arrayidx11 = getelementptr inbounds i8, ptr %11, i64 11
  store i8 5, ptr %arrayidx11, align 1
  %12 = load ptr, ptr %mem, align 8
  %arrayidx12 = getelementptr inbounds i8, ptr %12, i64 12
  store i8 -123, ptr %arrayidx12, align 1
  %13 = load ptr, ptr %mem, align 8
  %arrayidx13 = getelementptr inbounds i8, ptr %13, i64 13
  store i8 34, ptr %arrayidx13, align 1
  %14 = load ptr, ptr %mem, align 8
  %arrayidx14 = getelementptr inbounds i8, ptr %14, i64 14
  store i8 -26, ptr %arrayidx14, align 1
  %15 = load ptr, ptr %mem, align 8
  %arrayidx15 = getelementptr inbounds i8, ptr %15, i64 15
  store i8 33, ptr %arrayidx15, align 1
  %16 = load ptr, ptr %mem, align 8
  %arrayidx16 = getelementptr inbounds i8, ptr %16, i64 16
  store i8 -91, ptr %arrayidx16, align 1
  %17 = load ptr, ptr %mem, align 8
  %arrayidx17 = getelementptr inbounds i8, ptr %17, i64 17
  store i8 33, ptr %arrayidx17, align 1
  %18 = load ptr, ptr %mem, align 8
  %arrayidx18 = getelementptr inbounds i8, ptr %18, i64 18
  store i8 -59, ptr %arrayidx18, align 1
  %19 = load ptr, ptr %mem, align 8
  %arrayidx19 = getelementptr inbounds i8, ptr %19, i64 19
  store i8 32, ptr %arrayidx19, align 1
  %20 = load ptr, ptr %mem, align 8
  %arrayidx20 = getelementptr inbounds i8, ptr %20, i64 20
  store i8 -48, ptr %arrayidx20, align 1
  %21 = load ptr, ptr %mem, align 8
  %arrayidx21 = getelementptr inbounds i8, ptr %21, i64 21
  store i8 -14, ptr %arrayidx21, align 1
  %22 = load ptr, ptr %mem, align 8
  %arrayidx22 = getelementptr inbounds i8, ptr %22, i64 22
  store i8 -91, ptr %arrayidx22, align 1
  %23 = load ptr, ptr %mem, align 8
  %arrayidx23 = getelementptr inbounds i8, ptr %23, i64 23
  store i8 34, ptr %arrayidx23, align 1
  %24 = load ptr, ptr %mem, align 8
  %arrayidx24 = getelementptr inbounds i8, ptr %24, i64 24
  store i8 0, ptr %arrayidx24, align 1
  %25 = load i64, ptr %n.addr, align 8
  %and = and i64 %25, 255
  %conv = trunc i64 %and to i8
  %26 = load ptr, ptr %mem, align 8
  %arrayidx25 = getelementptr inbounds i8, ptr %26, i64 32
  store i8 %conv, ptr %arrayidx25, align 1
  store i64 0, ptr %A, align 8
  store i64 0, ptr %pc, align 8
  store i64 0, ptr %Z, align 8
  store i64 1, ptr %running, align 8
  store i64 0, ptr %budget, align 8
  br label %while.cond

while.cond:                                       ; preds = %if.end125, %entry
  %27 = load i64, ptr %running, align 8
  %cmp = icmp eq i64 %27, 1
  br i1 %cmp, label %land.rhs, label %land.end

land.rhs:                                         ; preds = %while.cond
  %28 = load i64, ptr %budget, align 8
  %cmp27 = icmp slt i64 %28, 4000
  br label %land.end

land.end:                                         ; preds = %land.rhs, %while.cond
  %29 = phi i1 [ false, %while.cond ], [ %cmp27, %land.rhs ]
  br i1 %29, label %while.body, label %while.end

while.body:                                       ; preds = %land.end
  %30 = load ptr, ptr %mem, align 8
  %31 = load i64, ptr %pc, align 8
  %arrayidx29 = getelementptr inbounds i8, ptr %30, i64 %31
  %32 = load i8, ptr %arrayidx29, align 1
  %conv30 = zext i8 %32 to i64
  store i64 %conv30, ptr %op, align 8
  %33 = load i64, ptr %op, align 8
  %cmp31 = icmp eq i64 %33, 169
  br i1 %cmp31, label %if.then, label %if.else

if.then:                                          ; preds = %while.body
  %34 = load ptr, ptr %mem, align 8
  %35 = load i64, ptr %pc, align 8
  %add = add nsw i64 %35, 1
  %arrayidx33 = getelementptr inbounds i8, ptr %34, i64 %add
  %36 = load i8, ptr %arrayidx33, align 1
  %conv34 = zext i8 %36 to i32
  %and35 = and i32 %conv34, 255
  %conv36 = sext i32 %and35 to i64
  store i64 %conv36, ptr %A, align 8
  %37 = load i64, ptr %pc, align 8
  %add37 = add nsw i64 %37, 2
  store i64 %add37, ptr %pc, align 8
  br label %if.end125

if.else:                                          ; preds = %while.body
  %38 = load i64, ptr %op, align 8
  %cmp38 = icmp eq i64 %38, 133
  br i1 %cmp38, label %if.then40, label %if.else47

if.then40:                                        ; preds = %if.else
  %39 = load ptr, ptr %mem, align 8
  %40 = load i64, ptr %pc, align 8
  %add41 = add nsw i64 %40, 1
  %arrayidx42 = getelementptr inbounds i8, ptr %39, i64 %add41
  %41 = load i8, ptr %arrayidx42, align 1
  %conv43 = zext i8 %41 to i64
  store i64 %conv43, ptr %a, align 8
  %42 = load i64, ptr %A, align 8
  %conv44 = trunc i64 %42 to i8
  %43 = load ptr, ptr %mem, align 8
  %44 = load i64, ptr %a, align 8
  %arrayidx45 = getelementptr inbounds i8, ptr %43, i64 %44
  store i8 %conv44, ptr %arrayidx45, align 1
  %45 = load i64, ptr %pc, align 8
  %add46 = add nsw i64 %45, 2
  store i64 %add46, ptr %pc, align 8
  br label %if.end124

if.else47:                                        ; preds = %if.else
  %46 = load i64, ptr %op, align 8
  %cmp48 = icmp eq i64 %46, 165
  br i1 %cmp48, label %if.then50, label %if.else60

if.then50:                                        ; preds = %if.else47
  %47 = load ptr, ptr %mem, align 8
  %48 = load i64, ptr %pc, align 8
  %add52 = add nsw i64 %48, 1
  %arrayidx53 = getelementptr inbounds i8, ptr %47, i64 %add52
  %49 = load i8, ptr %arrayidx53, align 1
  %conv54 = zext i8 %49 to i64
  store i64 %conv54, ptr %a51, align 8
  %50 = load ptr, ptr %mem, align 8
  %51 = load i64, ptr %a51, align 8
  %arrayidx55 = getelementptr inbounds i8, ptr %50, i64 %51
  %52 = load i8, ptr %arrayidx55, align 1
  %conv56 = zext i8 %52 to i32
  %and57 = and i32 %conv56, 255
  %conv58 = sext i32 %and57 to i64
  store i64 %conv58, ptr %A, align 8
  %53 = load i64, ptr %pc, align 8
  %add59 = add nsw i64 %53, 2
  store i64 %add59, ptr %pc, align 8
  br label %if.end123

if.else60:                                        ; preds = %if.else47
  %54 = load i64, ptr %op, align 8
  %cmp61 = icmp eq i64 %54, 105
  br i1 %cmp61, label %if.then63, label %if.else70

if.then63:                                        ; preds = %if.else60
  %55 = load i64, ptr %A, align 8
  %56 = load ptr, ptr %mem, align 8
  %57 = load i64, ptr %pc, align 8
  %add64 = add nsw i64 %57, 1
  %arrayidx65 = getelementptr inbounds i8, ptr %56, i64 %add64
  %58 = load i8, ptr %arrayidx65, align 1
  %conv66 = zext i8 %58 to i64
  %add67 = add nsw i64 %55, %conv66
  %and68 = and i64 %add67, 255
  store i64 %and68, ptr %A, align 8
  %59 = load i64, ptr %pc, align 8
  %add69 = add nsw i64 %59, 2
  store i64 %add69, ptr %pc, align 8
  br label %if.end122

if.else70:                                        ; preds = %if.else60
  %60 = load i64, ptr %op, align 8
  %cmp71 = icmp eq i64 %60, 230
  br i1 %cmp71, label %if.then73, label %if.else85

if.then73:                                        ; preds = %if.else70
  %61 = load ptr, ptr %mem, align 8
  %62 = load i64, ptr %pc, align 8
  %add75 = add nsw i64 %62, 1
  %arrayidx76 = getelementptr inbounds i8, ptr %61, i64 %add75
  %63 = load i8, ptr %arrayidx76, align 1
  %conv77 = zext i8 %63 to i64
  store i64 %conv77, ptr %a74, align 8
  %64 = load ptr, ptr %mem, align 8
  %65 = load i64, ptr %a74, align 8
  %arrayidx78 = getelementptr inbounds i8, ptr %64, i64 %65
  %66 = load i8, ptr %arrayidx78, align 1
  %conv79 = zext i8 %66 to i32
  %add80 = add nsw i32 %conv79, 1
  %and81 = and i32 %add80, 255
  %conv82 = trunc i32 %and81 to i8
  %67 = load ptr, ptr %mem, align 8
  %68 = load i64, ptr %a74, align 8
  %arrayidx83 = getelementptr inbounds i8, ptr %67, i64 %68
  store i8 %conv82, ptr %arrayidx83, align 1
  %69 = load i64, ptr %pc, align 8
  %add84 = add nsw i64 %69, 2
  store i64 %add84, ptr %pc, align 8
  br label %if.end121

if.else85:                                        ; preds = %if.else70
  %70 = load i64, ptr %op, align 8
  %cmp86 = icmp eq i64 %70, 197
  br i1 %cmp86, label %if.then88, label %if.else101

if.then88:                                        ; preds = %if.else85
  %71 = load ptr, ptr %mem, align 8
  %72 = load i64, ptr %pc, align 8
  %add90 = add nsw i64 %72, 1
  %arrayidx91 = getelementptr inbounds i8, ptr %71, i64 %add90
  %73 = load i8, ptr %arrayidx91, align 1
  %conv92 = zext i8 %73 to i64
  store i64 %conv92, ptr %a89, align 8
  %74 = load i64, ptr %A, align 8
  %75 = load ptr, ptr %mem, align 8
  %76 = load i64, ptr %a89, align 8
  %arrayidx93 = getelementptr inbounds i8, ptr %75, i64 %76
  %77 = load i8, ptr %arrayidx93, align 1
  %conv94 = zext i8 %77 to i32
  %and95 = and i32 %conv94, 255
  %conv96 = sext i32 %and95 to i64
  %cmp97 = icmp eq i64 %74, %conv96
  %78 = zext i1 %cmp97 to i64
  %cond = select i1 %cmp97, i32 1, i32 0
  %conv99 = sext i32 %cond to i64
  store i64 %conv99, ptr %Z, align 8
  %79 = load i64, ptr %pc, align 8
  %add100 = add nsw i64 %79, 2
  store i64 %add100, ptr %pc, align 8
  br label %if.end120

if.else101:                                       ; preds = %if.else85
  %80 = load i64, ptr %op, align 8
  %cmp102 = icmp eq i64 %80, 208
  br i1 %cmp102, label %if.then104, label %if.else117

if.then104:                                       ; preds = %if.else101
  %81 = load ptr, ptr %mem, align 8
  %82 = load i64, ptr %pc, align 8
  %add105 = add nsw i64 %82, 1
  %arrayidx106 = getelementptr inbounds i8, ptr %81, i64 %add105
  %83 = load i8, ptr %arrayidx106, align 1
  %conv107 = zext i8 %83 to i64
  store i64 %conv107, ptr %rel, align 8
  %84 = load i64, ptr %pc, align 8
  %add108 = add nsw i64 %84, 2
  store i64 %add108, ptr %pc, align 8
  %85 = load i64, ptr %rel, align 8
  %cmp109 = icmp sge i64 %85, 128
  br i1 %cmp109, label %if.then111, label %if.end

if.then111:                                       ; preds = %if.then104
  %86 = load i64, ptr %rel, align 8
  %sub = sub nsw i64 %86, 256
  store i64 %sub, ptr %rel, align 8
  br label %if.end

if.end:                                           ; preds = %if.then111, %if.then104
  %87 = load i64, ptr %Z, align 8
  %cmp112 = icmp eq i64 %87, 0
  br i1 %cmp112, label %if.then114, label %if.end116

if.then114:                                       ; preds = %if.end
  %88 = load i64, ptr %rel, align 8
  %89 = load i64, ptr %pc, align 8
  %add115 = add nsw i64 %89, %88
  store i64 %add115, ptr %pc, align 8
  br label %if.end116

if.end116:                                        ; preds = %if.then114, %if.end
  br label %if.end119

if.else117:                                       ; preds = %if.else101
  store i64 0, ptr %running, align 8
  %90 = load i64, ptr %pc, align 8
  %add118 = add nsw i64 %90, 1
  store i64 %add118, ptr %pc, align 8
  br label %if.end119

if.end119:                                        ; preds = %if.else117, %if.end116
  br label %if.end120

if.end120:                                        ; preds = %if.end119, %if.then88
  br label %if.end121

if.end121:                                        ; preds = %if.end120, %if.then73
  br label %if.end122

if.end122:                                        ; preds = %if.end121, %if.then63
  br label %if.end123

if.end123:                                        ; preds = %if.end122, %if.then50
  br label %if.end124

if.end124:                                        ; preds = %if.end123, %if.then40
  br label %if.end125

if.end125:                                        ; preds = %if.end124, %if.then
  %91 = load i64, ptr %budget, align 8
  %inc = add nsw i64 %91, 1
  store i64 %inc, ptr %budget, align 8
  br label %while.cond, !llvm.loop !6

while.end:                                        ; preds = %land.end
  %92 = load ptr, ptr %mem, align 8
  call void @free(ptr noundef %92) #4
  %93 = load i64, ptr %A, align 8
  ret i64 %93
}

; Function Attrs: nounwind allocsize(0,1)
declare noalias ptr @calloc(i64 noundef, i64 noundef) #1

; Function Attrs: nounwind
declare void @free(ptr noundef) #2

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind allocsize(0,1) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0,1) }
attributes #4 = { nounwind }

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
