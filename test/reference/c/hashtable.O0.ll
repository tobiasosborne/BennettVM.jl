; ModuleID = 'hashtable.c'
source_filename = "hashtable.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

%struct.ht = type { ptr, ptr, i64, i64 }

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i64 @ht_demo_basic(i64 noundef %n) #0 {
entry:
  %n.addr = alloca i64, align 8
  %t = alloca ptr, align 8
  %j = alloca i64, align 8
  %j3 = alloca i64, align 8
  %checksum = alloca i64, align 8
  %j11 = alloca i64, align 8
  %found = alloca i64, align 8
  %v = alloca i64, align 8
  store i64 %n, ptr %n.addr, align 8
  %call = call ptr @ht_new(i64 noundef 2048)
  store ptr %call, ptr %t, align 8
  store i64 0, ptr %j, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %0 = load i64, ptr %j, align 8
  %1 = load i64, ptr %n.addr, align 8
  %cmp = icmp slt i64 %0, %1
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %2 = load ptr, ptr %t, align 8
  %3 = load i64, ptr %j, align 8
  %call1 = call i64 @demo_key(i64 noundef %3)
  %4 = load i64, ptr %j, align 8
  %call2 = call i64 @demo_val(i64 noundef %4)
  call void @ht_put(ptr noundef %2, i64 noundef %call1, i64 noundef %call2)
  br label %for.inc

for.inc:                                          ; preds = %for.body
  %5 = load i64, ptr %j, align 8
  %inc = add nsw i64 %5, 1
  store i64 %inc, ptr %j, align 8
  br label %for.cond, !llvm.loop !6

for.end:                                          ; preds = %for.cond
  store i64 0, ptr %j3, align 8
  br label %for.cond4

for.cond4:                                        ; preds = %for.inc9, %for.end
  %6 = load i64, ptr %j3, align 8
  %7 = load i64, ptr %n.addr, align 8
  %cmp5 = icmp slt i64 %6, %7
  br i1 %cmp5, label %for.body6, label %for.end10

for.body6:                                        ; preds = %for.cond4
  %8 = load ptr, ptr %t, align 8
  %9 = load i64, ptr %j3, align 8
  %call7 = call i64 @demo_key(i64 noundef %9)
  %call8 = call i64 @ht_del(ptr noundef %8, i64 noundef %call7)
  br label %for.inc9

for.inc9:                                         ; preds = %for.body6
  %10 = load i64, ptr %j3, align 8
  %add = add nsw i64 %10, 3
  store i64 %add, ptr %j3, align 8
  br label %for.cond4, !llvm.loop !8

for.end10:                                        ; preds = %for.cond4
  %11 = load ptr, ptr %t, align 8
  %12 = load i64, ptr %n.addr, align 8
  call void @ht_third_pass(ptr noundef %11, i64 noundef %12)
  store i64 0, ptr %checksum, align 8
  store i64 0, ptr %j11, align 8
  br label %for.cond12

for.cond12:                                       ; preds = %for.inc19, %for.end10
  %13 = load i64, ptr %j11, align 8
  %14 = load i64, ptr %n.addr, align 8
  %cmp13 = icmp slt i64 %13, %14
  br i1 %cmp13, label %for.body14, label %for.end21

for.body14:                                       ; preds = %for.cond12
  store i64 0, ptr %found, align 8
  %15 = load ptr, ptr %t, align 8
  %16 = load i64, ptr %j11, align 8
  %call15 = call i64 @demo_key(i64 noundef %16)
  %call16 = call i64 @ht_get(ptr noundef %15, i64 noundef %call15, ptr noundef %found)
  store i64 %call16, ptr %v, align 8
  %17 = load i64, ptr %found, align 8
  %tobool = icmp ne i64 %17, 0
  br i1 %tobool, label %if.then, label %if.else

if.then:                                          ; preds = %for.body14
  %18 = load i64, ptr %v, align 8
  %19 = load i64, ptr %j11, align 8
  %mul = mul nsw i64 %19, 131
  %xor = xor i64 %18, %mul
  %20 = load i64, ptr %checksum, align 8
  %add17 = add nsw i64 %20, %xor
  store i64 %add17, ptr %checksum, align 8
  br label %if.end

if.else:                                          ; preds = %for.body14
  %21 = load i64, ptr %j11, align 8
  %add18 = add nsw i64 %21, 1
  %22 = load i64, ptr %checksum, align 8
  %sub = sub nsw i64 %22, %add18
  store i64 %sub, ptr %checksum, align 8
  br label %if.end

if.end:                                           ; preds = %if.else, %if.then
  br label %for.inc19

for.inc19:                                        ; preds = %if.end
  %23 = load i64, ptr %j11, align 8
  %inc20 = add nsw i64 %23, 1
  store i64 %inc20, ptr %j11, align 8
  br label %for.cond12, !llvm.loop !9

for.end21:                                        ; preds = %for.cond12
  %24 = load i64, ptr %checksum, align 8
  %mul22 = mul nsw i64 %24, 1000003
  %25 = load ptr, ptr %t, align 8
  %len = getelementptr inbounds %struct.ht, ptr %25, i32 0, i32 3
  %26 = load i64, ptr %len, align 8
  %add23 = add nsw i64 %mul22, %26
  store i64 %add23, ptr %checksum, align 8
  %27 = load ptr, ptr %t, align 8
  call void @ht_free(ptr noundef %27)
  %28 = load i64, ptr %checksum, align 8
  ret i64 %28
}

; Function Attrs: noinline nounwind optnone uwtable
define internal ptr @ht_new(i64 noundef %cap) #0 {
entry:
  %cap.addr = alloca i64, align 8
  %t = alloca ptr, align 8
  %i = alloca i64, align 8
  store i64 %cap, ptr %cap.addr, align 8
  %call = call noalias ptr @malloc(i64 noundef 32) #3
  store ptr %call, ptr %t, align 8
  %0 = load i64, ptr %cap.addr, align 8
  %mul = mul i64 %0, 8
  %call1 = call noalias ptr @malloc(i64 noundef %mul) #3
  %1 = load ptr, ptr %t, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %1, i32 0, i32 0
  store ptr %call1, ptr %keys, align 8
  %2 = load i64, ptr %cap.addr, align 8
  %mul2 = mul i64 %2, 8
  %call3 = call noalias ptr @malloc(i64 noundef %mul2) #3
  %3 = load ptr, ptr %t, align 8
  %vals = getelementptr inbounds %struct.ht, ptr %3, i32 0, i32 1
  store ptr %call3, ptr %vals, align 8
  %4 = load i64, ptr %cap.addr, align 8
  %5 = load ptr, ptr %t, align 8
  %cap4 = getelementptr inbounds %struct.ht, ptr %5, i32 0, i32 2
  store i64 %4, ptr %cap4, align 8
  %6 = load ptr, ptr %t, align 8
  %len = getelementptr inbounds %struct.ht, ptr %6, i32 0, i32 3
  store i64 0, ptr %len, align 8
  store i64 0, ptr %i, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %7 = load i64, ptr %i, align 8
  %8 = load i64, ptr %cap.addr, align 8
  %cmp = icmp slt i64 %7, %8
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %9 = load ptr, ptr %t, align 8
  %keys5 = getelementptr inbounds %struct.ht, ptr %9, i32 0, i32 0
  %10 = load ptr, ptr %keys5, align 8
  %11 = load i64, ptr %i, align 8
  %arrayidx = getelementptr inbounds i64, ptr %10, i64 %11
  store i64 -9223372036854775808, ptr %arrayidx, align 8
  %12 = load ptr, ptr %t, align 8
  %vals6 = getelementptr inbounds %struct.ht, ptr %12, i32 0, i32 1
  %13 = load ptr, ptr %vals6, align 8
  %14 = load i64, ptr %i, align 8
  %arrayidx7 = getelementptr inbounds i64, ptr %13, i64 %14
  store i64 0, ptr %arrayidx7, align 8
  br label %for.inc

for.inc:                                          ; preds = %for.body
  %15 = load i64, ptr %i, align 8
  %inc = add nsw i64 %15, 1
  store i64 %inc, ptr %i, align 8
  br label %for.cond, !llvm.loop !10

for.end:                                          ; preds = %for.cond
  %16 = load ptr, ptr %t, align 8
  ret ptr %16
}

; Function Attrs: noinline nounwind optnone uwtable
define internal void @ht_put(ptr noundef %t, i64 noundef %key, i64 noundef %val) #0 {
entry:
  %t.addr = alloca ptr, align 8
  %key.addr = alloca i64, align 8
  %val.addr = alloca i64, align 8
  %mask = alloca i64, align 8
  %i = alloca i64, align 8
  %first_tomb = alloca i64, align 8
  %probe = alloca i64, align 8
  %k = alloca i64, align 8
  %dst = alloca i64, align 8
  store ptr %t, ptr %t.addr, align 8
  store i64 %key, ptr %key.addr, align 8
  store i64 %val, ptr %val.addr, align 8
  %0 = load ptr, ptr %t.addr, align 8
  %cap = getelementptr inbounds %struct.ht, ptr %0, i32 0, i32 2
  %1 = load i64, ptr %cap, align 8
  %sub = sub nsw i64 %1, 1
  store i64 %sub, ptr %mask, align 8
  %2 = load i64, ptr %key.addr, align 8
  %call = call i64 @ht_hash(i64 noundef %2)
  %3 = load i64, ptr %mask, align 8
  %and = and i64 %call, %3
  store i64 %and, ptr %i, align 8
  store i64 -1, ptr %first_tomb, align 8
  store i64 0, ptr %probe, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %4 = load i64, ptr %probe, align 8
  %5 = load ptr, ptr %t.addr, align 8
  %cap1 = getelementptr inbounds %struct.ht, ptr %5, i32 0, i32 2
  %6 = load i64, ptr %cap1, align 8
  %cmp = icmp slt i64 %4, %6
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %7 = load ptr, ptr %t.addr, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %7, i32 0, i32 0
  %8 = load ptr, ptr %keys, align 8
  %9 = load i64, ptr %i, align 8
  %arrayidx = getelementptr inbounds i64, ptr %8, i64 %9
  %10 = load i64, ptr %arrayidx, align 8
  store i64 %10, ptr %k, align 8
  %11 = load i64, ptr %k, align 8
  %cmp2 = icmp eq i64 %11, -9223372036854775808
  br i1 %cmp2, label %if.then, label %if.end

if.then:                                          ; preds = %for.body
  %12 = load i64, ptr %first_tomb, align 8
  %cmp3 = icmp sge i64 %12, 0
  br i1 %cmp3, label %cond.true, label %cond.false

cond.true:                                        ; preds = %if.then
  %13 = load i64, ptr %first_tomb, align 8
  br label %cond.end

cond.false:                                       ; preds = %if.then
  %14 = load i64, ptr %i, align 8
  br label %cond.end

cond.end:                                         ; preds = %cond.false, %cond.true
  %cond = phi i64 [ %13, %cond.true ], [ %14, %cond.false ]
  store i64 %cond, ptr %dst, align 8
  %15 = load i64, ptr %key.addr, align 8
  %16 = load ptr, ptr %t.addr, align 8
  %keys4 = getelementptr inbounds %struct.ht, ptr %16, i32 0, i32 0
  %17 = load ptr, ptr %keys4, align 8
  %18 = load i64, ptr %dst, align 8
  %arrayidx5 = getelementptr inbounds i64, ptr %17, i64 %18
  store i64 %15, ptr %arrayidx5, align 8
  %19 = load i64, ptr %val.addr, align 8
  %20 = load ptr, ptr %t.addr, align 8
  %vals = getelementptr inbounds %struct.ht, ptr %20, i32 0, i32 1
  %21 = load ptr, ptr %vals, align 8
  %22 = load i64, ptr %dst, align 8
  %arrayidx6 = getelementptr inbounds i64, ptr %21, i64 %22
  store i64 %19, ptr %arrayidx6, align 8
  %23 = load ptr, ptr %t.addr, align 8
  %len = getelementptr inbounds %struct.ht, ptr %23, i32 0, i32 3
  %24 = load i64, ptr %len, align 8
  %inc = add nsw i64 %24, 1
  store i64 %inc, ptr %len, align 8
  br label %for.end

if.end:                                           ; preds = %for.body
  %25 = load i64, ptr %k, align 8
  %cmp7 = icmp eq i64 %25, -9223372036854775807
  br i1 %cmp7, label %if.then8, label %if.else

if.then8:                                         ; preds = %if.end
  %26 = load i64, ptr %first_tomb, align 8
  %cmp9 = icmp slt i64 %26, 0
  br i1 %cmp9, label %if.then10, label %if.end11

if.then10:                                        ; preds = %if.then8
  %27 = load i64, ptr %i, align 8
  store i64 %27, ptr %first_tomb, align 8
  br label %if.end11

if.end11:                                         ; preds = %if.then10, %if.then8
  br label %if.end17

if.else:                                          ; preds = %if.end
  %28 = load i64, ptr %k, align 8
  %29 = load i64, ptr %key.addr, align 8
  %cmp12 = icmp eq i64 %28, %29
  br i1 %cmp12, label %if.then13, label %if.end16

if.then13:                                        ; preds = %if.else
  %30 = load i64, ptr %val.addr, align 8
  %31 = load ptr, ptr %t.addr, align 8
  %vals14 = getelementptr inbounds %struct.ht, ptr %31, i32 0, i32 1
  %32 = load ptr, ptr %vals14, align 8
  %33 = load i64, ptr %i, align 8
  %arrayidx15 = getelementptr inbounds i64, ptr %32, i64 %33
  store i64 %30, ptr %arrayidx15, align 8
  br label %for.end

if.end16:                                         ; preds = %if.else
  br label %if.end17

if.end17:                                         ; preds = %if.end16, %if.end11
  %34 = load i64, ptr %i, align 8
  %add = add nsw i64 %34, 1
  %35 = load i64, ptr %mask, align 8
  %and18 = and i64 %add, %35
  store i64 %and18, ptr %i, align 8
  br label %for.inc

for.inc:                                          ; preds = %if.end17
  %36 = load i64, ptr %probe, align 8
  %inc19 = add nsw i64 %36, 1
  store i64 %inc19, ptr %probe, align 8
  br label %for.cond, !llvm.loop !11

for.end:                                          ; preds = %cond.end, %if.then13, %for.cond
  ret void
}

; Function Attrs: noinline nounwind optnone uwtable
define internal i64 @demo_key(i64 noundef %j) #0 {
entry:
  %j.addr = alloca i64, align 8
  store i64 %j, ptr %j.addr, align 8
  %0 = load i64, ptr %j.addr, align 8
  %mul = mul nsw i64 %0, 2654435761
  %add = add nsw i64 %mul, 7
  ret i64 %add
}

; Function Attrs: noinline nounwind optnone uwtable
define internal i64 @demo_val(i64 noundef %j) #0 {
entry:
  %j.addr = alloca i64, align 8
  store i64 %j, ptr %j.addr, align 8
  %0 = load i64, ptr %j.addr, align 8
  %xor = xor i64 %0, 23130
  %1 = load i64, ptr %j.addr, align 8
  %mul = mul nsw i64 3, %1
  %add = add nsw i64 %xor, %mul
  ret i64 %add
}

; Function Attrs: noinline nounwind optnone uwtable
define internal i64 @ht_del(ptr noundef %t, i64 noundef %key) #0 {
entry:
  %retval = alloca i64, align 8
  %t.addr = alloca ptr, align 8
  %key.addr = alloca i64, align 8
  %mask = alloca i64, align 8
  %i = alloca i64, align 8
  %probe = alloca i64, align 8
  %k = alloca i64, align 8
  store ptr %t, ptr %t.addr, align 8
  store i64 %key, ptr %key.addr, align 8
  %0 = load ptr, ptr %t.addr, align 8
  %cap = getelementptr inbounds %struct.ht, ptr %0, i32 0, i32 2
  %1 = load i64, ptr %cap, align 8
  %sub = sub nsw i64 %1, 1
  store i64 %sub, ptr %mask, align 8
  %2 = load i64, ptr %key.addr, align 8
  %call = call i64 @ht_hash(i64 noundef %2)
  %3 = load i64, ptr %mask, align 8
  %and = and i64 %call, %3
  store i64 %and, ptr %i, align 8
  store i64 0, ptr %probe, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %4 = load i64, ptr %probe, align 8
  %5 = load ptr, ptr %t.addr, align 8
  %cap1 = getelementptr inbounds %struct.ht, ptr %5, i32 0, i32 2
  %6 = load i64, ptr %cap1, align 8
  %cmp = icmp slt i64 %4, %6
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %7 = load ptr, ptr %t.addr, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %7, i32 0, i32 0
  %8 = load ptr, ptr %keys, align 8
  %9 = load i64, ptr %i, align 8
  %arrayidx = getelementptr inbounds i64, ptr %8, i64 %9
  %10 = load i64, ptr %arrayidx, align 8
  store i64 %10, ptr %k, align 8
  %11 = load i64, ptr %k, align 8
  %cmp2 = icmp eq i64 %11, -9223372036854775808
  br i1 %cmp2, label %if.then, label %if.end

if.then:                                          ; preds = %for.body
  store i64 0, ptr %retval, align 8
  br label %return

if.end:                                           ; preds = %for.body
  %12 = load i64, ptr %k, align 8
  %13 = load i64, ptr %key.addr, align 8
  %cmp3 = icmp eq i64 %12, %13
  br i1 %cmp3, label %if.then4, label %if.end7

if.then4:                                         ; preds = %if.end
  %14 = load ptr, ptr %t.addr, align 8
  %keys5 = getelementptr inbounds %struct.ht, ptr %14, i32 0, i32 0
  %15 = load ptr, ptr %keys5, align 8
  %16 = load i64, ptr %i, align 8
  %arrayidx6 = getelementptr inbounds i64, ptr %15, i64 %16
  store i64 -9223372036854775807, ptr %arrayidx6, align 8
  %17 = load ptr, ptr %t.addr, align 8
  %len = getelementptr inbounds %struct.ht, ptr %17, i32 0, i32 3
  %18 = load i64, ptr %len, align 8
  %dec = add nsw i64 %18, -1
  store i64 %dec, ptr %len, align 8
  store i64 1, ptr %retval, align 8
  br label %return

if.end7:                                          ; preds = %if.end
  %19 = load i64, ptr %i, align 8
  %add = add nsw i64 %19, 1
  %20 = load i64, ptr %mask, align 8
  %and8 = and i64 %add, %20
  store i64 %and8, ptr %i, align 8
  br label %for.inc

for.inc:                                          ; preds = %if.end7
  %21 = load i64, ptr %probe, align 8
  %inc = add nsw i64 %21, 1
  store i64 %inc, ptr %probe, align 8
  br label %for.cond, !llvm.loop !12

for.end:                                          ; preds = %for.cond
  store i64 0, ptr %retval, align 8
  br label %return

return:                                           ; preds = %for.end, %if.then4, %if.then
  %22 = load i64, ptr %retval, align 8
  ret i64 %22
}

; Function Attrs: noinline nounwind optnone uwtable
define internal void @ht_third_pass(ptr noundef %t, i64 noundef %n) #0 {
entry:
  %t.addr = alloca ptr, align 8
  %n.addr = alloca i64, align 8
  %j = alloca i64, align 8
  store ptr %t, ptr %t.addr, align 8
  store i64 %n, ptr %n.addr, align 8
  store i64 0, ptr %j, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %0 = load i64, ptr %j, align 8
  %1 = load i64, ptr %n.addr, align 8
  %cmp = icmp slt i64 %0, %1
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %2 = load ptr, ptr %t.addr, align 8
  %3 = load i64, ptr %j, align 8
  %call = call i64 @demo_key(i64 noundef %3)
  %4 = load i64, ptr %j, align 8
  %call1 = call i64 @demo_val(i64 noundef %4)
  %add = add nsw i64 %call1, 1
  call void @ht_put(ptr noundef %2, i64 noundef %call, i64 noundef %add)
  br label %for.inc

for.inc:                                          ; preds = %for.body
  %5 = load i64, ptr %j, align 8
  %add2 = add nsw i64 %5, 6
  store i64 %add2, ptr %j, align 8
  br label %for.cond, !llvm.loop !13

for.end:                                          ; preds = %for.cond
  %6 = load i64, ptr %n.addr, align 8
  %cmp3 = icmp sgt i64 %6, 1
  br i1 %cmp3, label %if.then, label %if.end

if.then:                                          ; preds = %for.end
  %7 = load ptr, ptr %t.addr, align 8
  %call4 = call i64 @demo_key(i64 noundef 1)
  %call5 = call i64 @demo_val(i64 noundef 1)
  %add6 = add nsw i64 %call5, 1
  call void @ht_put(ptr noundef %7, i64 noundef %call4, i64 noundef %add6)
  br label %if.end

if.end:                                           ; preds = %if.then, %for.end
  %8 = load ptr, ptr %t.addr, align 8
  %call7 = call i64 @ht_del(ptr noundef %8, i64 noundef 3)
  ret void
}

; Function Attrs: noinline nounwind optnone uwtable
define internal i64 @ht_get(ptr noundef %t, i64 noundef %key, ptr noundef %found) #0 {
entry:
  %retval = alloca i64, align 8
  %t.addr = alloca ptr, align 8
  %key.addr = alloca i64, align 8
  %found.addr = alloca ptr, align 8
  %mask = alloca i64, align 8
  %i = alloca i64, align 8
  %probe = alloca i64, align 8
  %k = alloca i64, align 8
  store ptr %t, ptr %t.addr, align 8
  store i64 %key, ptr %key.addr, align 8
  store ptr %found, ptr %found.addr, align 8
  %0 = load ptr, ptr %t.addr, align 8
  %cap = getelementptr inbounds %struct.ht, ptr %0, i32 0, i32 2
  %1 = load i64, ptr %cap, align 8
  %sub = sub nsw i64 %1, 1
  store i64 %sub, ptr %mask, align 8
  %2 = load i64, ptr %key.addr, align 8
  %call = call i64 @ht_hash(i64 noundef %2)
  %3 = load i64, ptr %mask, align 8
  %and = and i64 %call, %3
  store i64 %and, ptr %i, align 8
  store i64 0, ptr %probe, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %4 = load i64, ptr %probe, align 8
  %5 = load ptr, ptr %t.addr, align 8
  %cap1 = getelementptr inbounds %struct.ht, ptr %5, i32 0, i32 2
  %6 = load i64, ptr %cap1, align 8
  %cmp = icmp slt i64 %4, %6
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %7 = load ptr, ptr %t.addr, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %7, i32 0, i32 0
  %8 = load ptr, ptr %keys, align 8
  %9 = load i64, ptr %i, align 8
  %arrayidx = getelementptr inbounds i64, ptr %8, i64 %9
  %10 = load i64, ptr %arrayidx, align 8
  store i64 %10, ptr %k, align 8
  %11 = load i64, ptr %k, align 8
  %cmp2 = icmp eq i64 %11, -9223372036854775808
  br i1 %cmp2, label %if.then, label %if.end

if.then:                                          ; preds = %for.body
  %12 = load ptr, ptr %found.addr, align 8
  store i64 0, ptr %12, align 8
  store i64 0, ptr %retval, align 8
  br label %return

if.end:                                           ; preds = %for.body
  %13 = load i64, ptr %k, align 8
  %14 = load i64, ptr %key.addr, align 8
  %cmp3 = icmp eq i64 %13, %14
  br i1 %cmp3, label %if.then4, label %if.end6

if.then4:                                         ; preds = %if.end
  %15 = load ptr, ptr %found.addr, align 8
  store i64 1, ptr %15, align 8
  %16 = load ptr, ptr %t.addr, align 8
  %vals = getelementptr inbounds %struct.ht, ptr %16, i32 0, i32 1
  %17 = load ptr, ptr %vals, align 8
  %18 = load i64, ptr %i, align 8
  %arrayidx5 = getelementptr inbounds i64, ptr %17, i64 %18
  %19 = load i64, ptr %arrayidx5, align 8
  store i64 %19, ptr %retval, align 8
  br label %return

if.end6:                                          ; preds = %if.end
  %20 = load i64, ptr %i, align 8
  %add = add nsw i64 %20, 1
  %21 = load i64, ptr %mask, align 8
  %and7 = and i64 %add, %21
  store i64 %and7, ptr %i, align 8
  br label %for.inc

for.inc:                                          ; preds = %if.end6
  %22 = load i64, ptr %probe, align 8
  %inc = add nsw i64 %22, 1
  store i64 %inc, ptr %probe, align 8
  br label %for.cond, !llvm.loop !14

for.end:                                          ; preds = %for.cond
  %23 = load ptr, ptr %found.addr, align 8
  store i64 0, ptr %23, align 8
  store i64 0, ptr %retval, align 8
  br label %return

return:                                           ; preds = %for.end, %if.then4, %if.then
  %24 = load i64, ptr %retval, align 8
  ret i64 %24
}

; Function Attrs: noinline nounwind optnone uwtable
define internal void @ht_free(ptr noundef %t) #0 {
entry:
  %t.addr = alloca ptr, align 8
  store ptr %t, ptr %t.addr, align 8
  %0 = load ptr, ptr %t.addr, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %0, i32 0, i32 0
  %1 = load ptr, ptr %keys, align 8
  call void @free(ptr noundef %1) #4
  %2 = load ptr, ptr %t.addr, align 8
  %vals = getelementptr inbounds %struct.ht, ptr %2, i32 0, i32 1
  %3 = load ptr, ptr %vals, align 8
  call void @free(ptr noundef %3) #4
  %4 = load ptr, ptr %t.addr, align 8
  call void @free(ptr noundef %4) #4
  ret void
}

; Function Attrs: noinline nounwind optnone uwtable
define dso_local i64 @ht_demo_grow(i64 noundef %n) #0 {
entry:
  %n.addr = alloca i64, align 8
  %t = alloca ptr, align 8
  %j = alloca i64, align 8
  %j5 = alloca i64, align 8
  %checksum = alloca i64, align 8
  %j14 = alloca i64, align 8
  %found = alloca i64, align 8
  %v = alloca i64, align 8
  store i64 %n, ptr %n.addr, align 8
  %call = call ptr @ht_new(i64 noundef 4)
  store ptr %call, ptr %t, align 8
  store i64 0, ptr %j, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %0 = load i64, ptr %j, align 8
  %1 = load i64, ptr %n.addr, align 8
  %cmp = icmp slt i64 %0, %1
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %2 = load ptr, ptr %t, align 8
  %len = getelementptr inbounds %struct.ht, ptr %2, i32 0, i32 3
  %3 = load i64, ptr %len, align 8
  %add = add nsw i64 %3, 1
  %mul = mul nsw i64 %add, 10
  %4 = load ptr, ptr %t, align 8
  %cap = getelementptr inbounds %struct.ht, ptr %4, i32 0, i32 2
  %5 = load i64, ptr %cap, align 8
  %mul1 = mul nsw i64 %5, 7
  %cmp2 = icmp sgt i64 %mul, %mul1
  br i1 %cmp2, label %if.then, label %if.end

if.then:                                          ; preds = %for.body
  %6 = load ptr, ptr %t, align 8
  call void @ht_grow(ptr noundef %6)
  br label %if.end

if.end:                                           ; preds = %if.then, %for.body
  %7 = load ptr, ptr %t, align 8
  %8 = load i64, ptr %j, align 8
  %call3 = call i64 @demo_key(i64 noundef %8)
  %9 = load i64, ptr %j, align 8
  %call4 = call i64 @demo_val(i64 noundef %9)
  call void @ht_put(ptr noundef %7, i64 noundef %call3, i64 noundef %call4)
  br label %for.inc

for.inc:                                          ; preds = %if.end
  %10 = load i64, ptr %j, align 8
  %inc = add nsw i64 %10, 1
  store i64 %inc, ptr %j, align 8
  br label %for.cond, !llvm.loop !15

for.end:                                          ; preds = %for.cond
  store i64 0, ptr %j5, align 8
  br label %for.cond6

for.cond6:                                        ; preds = %for.inc11, %for.end
  %11 = load i64, ptr %j5, align 8
  %12 = load i64, ptr %n.addr, align 8
  %cmp7 = icmp slt i64 %11, %12
  br i1 %cmp7, label %for.body8, label %for.end13

for.body8:                                        ; preds = %for.cond6
  %13 = load ptr, ptr %t, align 8
  %14 = load i64, ptr %j5, align 8
  %call9 = call i64 @demo_key(i64 noundef %14)
  %call10 = call i64 @ht_del(ptr noundef %13, i64 noundef %call9)
  br label %for.inc11

for.inc11:                                        ; preds = %for.body8
  %15 = load i64, ptr %j5, align 8
  %add12 = add nsw i64 %15, 3
  store i64 %add12, ptr %j5, align 8
  br label %for.cond6, !llvm.loop !16

for.end13:                                        ; preds = %for.cond6
  %16 = load ptr, ptr %t, align 8
  %17 = load i64, ptr %n.addr, align 8
  call void @ht_third_pass(ptr noundef %16, i64 noundef %17)
  store i64 0, ptr %checksum, align 8
  store i64 0, ptr %j14, align 8
  br label %for.cond15

for.cond15:                                       ; preds = %for.inc25, %for.end13
  %18 = load i64, ptr %j14, align 8
  %19 = load i64, ptr %n.addr, align 8
  %cmp16 = icmp slt i64 %18, %19
  br i1 %cmp16, label %for.body17, label %for.end27

for.body17:                                       ; preds = %for.cond15
  store i64 0, ptr %found, align 8
  %20 = load ptr, ptr %t, align 8
  %21 = load i64, ptr %j14, align 8
  %call18 = call i64 @demo_key(i64 noundef %21)
  %call19 = call i64 @ht_get(ptr noundef %20, i64 noundef %call18, ptr noundef %found)
  store i64 %call19, ptr %v, align 8
  %22 = load i64, ptr %found, align 8
  %tobool = icmp ne i64 %22, 0
  br i1 %tobool, label %if.then20, label %if.else

if.then20:                                        ; preds = %for.body17
  %23 = load i64, ptr %v, align 8
  %24 = load i64, ptr %j14, align 8
  %mul21 = mul nsw i64 %24, 131
  %xor = xor i64 %23, %mul21
  %25 = load i64, ptr %checksum, align 8
  %add22 = add nsw i64 %25, %xor
  store i64 %add22, ptr %checksum, align 8
  br label %if.end24

if.else:                                          ; preds = %for.body17
  %26 = load i64, ptr %j14, align 8
  %add23 = add nsw i64 %26, 1
  %27 = load i64, ptr %checksum, align 8
  %sub = sub nsw i64 %27, %add23
  store i64 %sub, ptr %checksum, align 8
  br label %if.end24

if.end24:                                         ; preds = %if.else, %if.then20
  br label %for.inc25

for.inc25:                                        ; preds = %if.end24
  %28 = load i64, ptr %j14, align 8
  %inc26 = add nsw i64 %28, 1
  store i64 %inc26, ptr %j14, align 8
  br label %for.cond15, !llvm.loop !17

for.end27:                                        ; preds = %for.cond15
  %29 = load i64, ptr %checksum, align 8
  %mul28 = mul nsw i64 %29, 1000003
  %30 = load ptr, ptr %t, align 8
  %len29 = getelementptr inbounds %struct.ht, ptr %30, i32 0, i32 3
  %31 = load i64, ptr %len29, align 8
  %mul30 = mul nsw i64 %31, 7
  %add31 = add nsw i64 %mul28, %mul30
  %32 = load ptr, ptr %t, align 8
  %cap32 = getelementptr inbounds %struct.ht, ptr %32, i32 0, i32 2
  %33 = load i64, ptr %cap32, align 8
  %add33 = add nsw i64 %add31, %33
  store i64 %add33, ptr %checksum, align 8
  %34 = load ptr, ptr %t, align 8
  call void @ht_free(ptr noundef %34)
  %35 = load i64, ptr %checksum, align 8
  ret i64 %35
}

; Function Attrs: noinline nounwind optnone uwtable
define internal void @ht_grow(ptr noundef %t) #0 {
entry:
  %t.addr = alloca ptr, align 8
  %old_cap = alloca i64, align 8
  %old_keys = alloca ptr, align 8
  %old_vals = alloca ptr, align 8
  %new_cap = alloca i64, align 8
  %i = alloca i64, align 8
  %i9 = alloca i64, align 8
  %k = alloca i64, align 8
  store ptr %t, ptr %t.addr, align 8
  %0 = load ptr, ptr %t.addr, align 8
  %cap = getelementptr inbounds %struct.ht, ptr %0, i32 0, i32 2
  %1 = load i64, ptr %cap, align 8
  store i64 %1, ptr %old_cap, align 8
  %2 = load ptr, ptr %t.addr, align 8
  %keys = getelementptr inbounds %struct.ht, ptr %2, i32 0, i32 0
  %3 = load ptr, ptr %keys, align 8
  store ptr %3, ptr %old_keys, align 8
  %4 = load ptr, ptr %t.addr, align 8
  %vals = getelementptr inbounds %struct.ht, ptr %4, i32 0, i32 1
  %5 = load ptr, ptr %vals, align 8
  store ptr %5, ptr %old_vals, align 8
  %6 = load i64, ptr %old_cap, align 8
  %shl = shl i64 %6, 1
  store i64 %shl, ptr %new_cap, align 8
  %7 = load i64, ptr %new_cap, align 8
  %mul = mul i64 %7, 8
  %call = call noalias ptr @malloc(i64 noundef %mul) #3
  %8 = load ptr, ptr %t.addr, align 8
  %keys1 = getelementptr inbounds %struct.ht, ptr %8, i32 0, i32 0
  store ptr %call, ptr %keys1, align 8
  %9 = load i64, ptr %new_cap, align 8
  %mul2 = mul i64 %9, 8
  %call3 = call noalias ptr @malloc(i64 noundef %mul2) #3
  %10 = load ptr, ptr %t.addr, align 8
  %vals4 = getelementptr inbounds %struct.ht, ptr %10, i32 0, i32 1
  store ptr %call3, ptr %vals4, align 8
  %11 = load i64, ptr %new_cap, align 8
  %12 = load ptr, ptr %t.addr, align 8
  %cap5 = getelementptr inbounds %struct.ht, ptr %12, i32 0, i32 2
  store i64 %11, ptr %cap5, align 8
  %13 = load ptr, ptr %t.addr, align 8
  %len = getelementptr inbounds %struct.ht, ptr %13, i32 0, i32 3
  store i64 0, ptr %len, align 8
  store i64 0, ptr %i, align 8
  br label %for.cond

for.cond:                                         ; preds = %for.inc, %entry
  %14 = load i64, ptr %i, align 8
  %15 = load i64, ptr %new_cap, align 8
  %cmp = icmp slt i64 %14, %15
  br i1 %cmp, label %for.body, label %for.end

for.body:                                         ; preds = %for.cond
  %16 = load ptr, ptr %t.addr, align 8
  %keys6 = getelementptr inbounds %struct.ht, ptr %16, i32 0, i32 0
  %17 = load ptr, ptr %keys6, align 8
  %18 = load i64, ptr %i, align 8
  %arrayidx = getelementptr inbounds i64, ptr %17, i64 %18
  store i64 -9223372036854775808, ptr %arrayidx, align 8
  %19 = load ptr, ptr %t.addr, align 8
  %vals7 = getelementptr inbounds %struct.ht, ptr %19, i32 0, i32 1
  %20 = load ptr, ptr %vals7, align 8
  %21 = load i64, ptr %i, align 8
  %arrayidx8 = getelementptr inbounds i64, ptr %20, i64 %21
  store i64 0, ptr %arrayidx8, align 8
  br label %for.inc

for.inc:                                          ; preds = %for.body
  %22 = load i64, ptr %i, align 8
  %inc = add nsw i64 %22, 1
  store i64 %inc, ptr %i, align 8
  br label %for.cond, !llvm.loop !18

for.end:                                          ; preds = %for.cond
  store i64 0, ptr %i9, align 8
  br label %for.cond10

for.cond10:                                       ; preds = %for.inc17, %for.end
  %23 = load i64, ptr %i9, align 8
  %24 = load i64, ptr %old_cap, align 8
  %cmp11 = icmp slt i64 %23, %24
  br i1 %cmp11, label %for.body12, label %for.end19

for.body12:                                       ; preds = %for.cond10
  %25 = load ptr, ptr %old_keys, align 8
  %26 = load i64, ptr %i9, align 8
  %arrayidx13 = getelementptr inbounds i64, ptr %25, i64 %26
  %27 = load i64, ptr %arrayidx13, align 8
  store i64 %27, ptr %k, align 8
  %28 = load i64, ptr %k, align 8
  %cmp14 = icmp ne i64 %28, -9223372036854775808
  br i1 %cmp14, label %land.lhs.true, label %if.end

land.lhs.true:                                    ; preds = %for.body12
  %29 = load i64, ptr %k, align 8
  %cmp15 = icmp ne i64 %29, -9223372036854775807
  br i1 %cmp15, label %if.then, label %if.end

if.then:                                          ; preds = %land.lhs.true
  %30 = load ptr, ptr %t.addr, align 8
  %31 = load i64, ptr %k, align 8
  %32 = load ptr, ptr %old_vals, align 8
  %33 = load i64, ptr %i9, align 8
  %arrayidx16 = getelementptr inbounds i64, ptr %32, i64 %33
  %34 = load i64, ptr %arrayidx16, align 8
  call void @ht_put(ptr noundef %30, i64 noundef %31, i64 noundef %34)
  br label %if.end

if.end:                                           ; preds = %if.then, %land.lhs.true, %for.body12
  br label %for.inc17

for.inc17:                                        ; preds = %if.end
  %35 = load i64, ptr %i9, align 8
  %inc18 = add nsw i64 %35, 1
  store i64 %inc18, ptr %i9, align 8
  br label %for.cond10, !llvm.loop !19

for.end19:                                        ; preds = %for.cond10
  %36 = load ptr, ptr %old_keys, align 8
  call void @free(ptr noundef %36) #4
  %37 = load ptr, ptr %old_vals, align 8
  call void @free(ptr noundef %37) #4
  ret void
}

; Function Attrs: nounwind allocsize(0)
declare noalias ptr @malloc(i64 noundef) #1

; Function Attrs: noinline nounwind optnone uwtable
define internal i64 @ht_hash(i64 noundef %key) #0 {
entry:
  %key.addr = alloca i64, align 8
  %z = alloca i64, align 8
  store i64 %key, ptr %key.addr, align 8
  %0 = load i64, ptr %key.addr, align 8
  store i64 %0, ptr %z, align 8
  %1 = load i64, ptr %z, align 8
  %2 = load i64, ptr %z, align 8
  %shr = lshr i64 %2, 30
  %xor = xor i64 %1, %shr
  %mul = mul i64 %xor, -4658895280553007687
  store i64 %mul, ptr %z, align 8
  %3 = load i64, ptr %z, align 8
  %4 = load i64, ptr %z, align 8
  %shr1 = lshr i64 %4, 27
  %xor2 = xor i64 %3, %shr1
  %mul3 = mul i64 %xor2, -7723592293110705685
  store i64 %mul3, ptr %z, align 8
  %5 = load i64, ptr %z, align 8
  %6 = load i64, ptr %z, align 8
  %shr4 = lshr i64 %6, 31
  %xor5 = xor i64 %5, %shr4
  store i64 %xor5, ptr %z, align 8
  %7 = load i64, ptr %z, align 8
  ret i64 %7
}

; Function Attrs: nounwind
declare void @free(ptr noundef) #2

attributes #0 = { noinline nounwind optnone uwtable "frame-pointer"="all" "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nounwind allocsize(0) "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { nounwind "frame-pointer"="all" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { nounwind allocsize(0) }
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
!8 = distinct !{!8, !7}
!9 = distinct !{!9, !7}
!10 = distinct !{!10, !7}
!11 = distinct !{!11, !7}
!12 = distinct !{!12, !7}
!13 = distinct !{!13, !7}
!14 = distinct !{!14, !7}
!15 = distinct !{!15, !7}
!16 = distinct !{!16, !7}
!17 = distinct !{!17, !7}
!18 = distinct !{!18, !7}
!19 = distinct !{!19, !7}
