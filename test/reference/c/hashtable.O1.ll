; ModuleID = 'hashtable.c'
source_filename = "hashtable.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-pc-linux-gnu"

%struct.ht = type { ptr, ptr, i64, i64 }

; Function Attrs: nounwind uwtable
define dso_local i64 @ht_demo_basic(i64 noundef %n) local_unnamed_addr #0 {
entry:
  %call.i = tail call noalias dereferenceable_or_null(32) ptr @malloc(i64 noundef 32) #5
  %call1.i = tail call noalias dereferenceable_or_null(16384) ptr @malloc(i64 noundef 16384) #5
  store ptr %call1.i, ptr %call.i, align 8, !tbaa !5
  %call3.i = tail call noalias dereferenceable_or_null(16384) ptr @malloc(i64 noundef 16384) #5
  %vals.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 1
  store ptr %call3.i, ptr %vals.i, align 8, !tbaa !11
  %cap4.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 2
  store i64 2048, ptr %cap4.i, align 8, !tbaa !12
  %len.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 3
  store i64 0, ptr %len.i, align 8, !tbaa !13
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(16384) %call3.i, i8 0, i64 16384, i1 false), !tbaa !14
  br label %for.body.i

for.body.i:                                       ; preds = %for.body.i, %entry
  %i.021.i = phi i64 [ %inc.i, %for.body.i ], [ 0, %entry ]
  %arrayidx.i = getelementptr inbounds i64, ptr %call1.i, i64 %i.021.i
  store i64 -9223372036854775808, ptr %arrayidx.i, align 8, !tbaa !14
  %inc.i = add nuw nsw i64 %i.021.i, 1
  %exitcond.not.i = icmp eq i64 %inc.i, 2048
  br i1 %exitcond.not.i, label %for.cond.preheader, label %for.body.i, !llvm.loop !15

for.cond.preheader:                               ; preds = %for.body.i
  %cmp115 = icmp sgt i64 %n, 0
  br i1 %cmp115, label %for.body, label %for.cond4.preheader

for.cond4.preheader:                              ; preds = %ht_put.exit, %for.cond.preheader
  %cmp5117 = icmp sgt i64 %n, 0
  br i1 %cmp5117, label %for.body7, label %for.cond.cleanup6

for.body:                                         ; preds = %for.cond.preheader, %ht_put.exit
  %j.0116 = phi i64 [ %inc, %ht_put.exit ], [ 0, %for.cond.preheader ]
  %mul.i = mul nsw i64 %j.0116, 2654435761
  %add.i = add nuw nsw i64 %mul.i, 7
  %xor.i = xor i64 %j.0116, 23130
  %mul.i46 = mul nsw i64 %j.0116, 3
  %add.i47 = add nuw nsw i64 %xor.i, %mul.i46
  %shr.i.i = lshr i64 %add.i, 30
  %xor.i.i = xor i64 %shr.i.i, %add.i
  %mul.i.i = mul i64 %xor.i.i, -4658895280553007687
  %shr1.i.i = lshr i64 %mul.i.i, 27
  %xor2.i.i = xor i64 %shr1.i.i, %mul.i.i
  %mul3.i.i = mul i64 %xor2.i.i, -7723592293110705685
  %shr4.i.i = lshr i64 %mul3.i.i, 31
  %xor5.i.i = xor i64 %shr4.i.i, %mul3.i.i
  %and.i = and i64 %xor5.i.i, 2047
  br label %for.body.i50

for.body.i50:                                     ; preds = %cleanup.i, %for.body
  %i.054.i = phi i64 [ %and.i, %for.body ], [ %i.1.i, %cleanup.i ]
  %first_tomb.053.i = phi i64 [ -1, %for.body ], [ %first_tomb.2.i, %cleanup.i ]
  %probe.052.i = phi i64 [ 0, %for.body ], [ %inc19.i, %cleanup.i ]
  %arrayidx.i51 = getelementptr inbounds i64, ptr %call1.i, i64 %i.054.i
  %0 = load i64, ptr %arrayidx.i51, align 8, !tbaa !14
  switch i64 %0, label %if.else.i [
    i64 -9223372036854775808, label %if.then.i
    i64 -9223372036854775807, label %if.then8.i
  ]

if.then.i:                                        ; preds = %for.body.i50
  %cmp350.i = icmp slt i64 %first_tomb.053.i, 0
  %cond.i = select i1 %cmp350.i, i64 %i.054.i, i64 %first_tomb.053.i
  %arrayidx5.i = getelementptr inbounds i64, ptr %call1.i, i64 %cond.i
  store i64 %add.i, ptr %arrayidx5.i, align 8, !tbaa !14
  %arrayidx6.i = getelementptr inbounds i64, ptr %call3.i, i64 %cond.i
  store i64 %add.i47, ptr %arrayidx6.i, align 8, !tbaa !14
  %1 = load i64, ptr %len.i, align 8, !tbaa !13
  %inc.i53 = add nsw i64 %1, 1
  store i64 %inc.i53, ptr %len.i, align 8, !tbaa !13
  br label %cleanup.i

if.then8.i:                                       ; preds = %for.body.i50
  %cmp9.i = icmp slt i64 %first_tomb.053.i, 0
  %spec.select.i = select i1 %cmp9.i, i64 %i.054.i, i64 %first_tomb.053.i
  br label %if.end17.i

if.else.i:                                        ; preds = %for.body.i50
  %cmp12.i = icmp eq i64 %0, %add.i
  br i1 %cmp12.i, label %if.then13.i, label %if.end17.i

if.then13.i:                                      ; preds = %if.else.i
  %arrayidx15.i = getelementptr inbounds i64, ptr %call3.i, i64 %i.054.i
  store i64 %add.i47, ptr %arrayidx15.i, align 8, !tbaa !14
  br label %cleanup.i

if.end17.i:                                       ; preds = %if.else.i, %if.then8.i
  %first_tomb.1.i = phi i64 [ %first_tomb.053.i, %if.else.i ], [ %spec.select.i, %if.then8.i ]
  %add.i52 = add nsw i64 %i.054.i, 1
  %and18.i = and i64 %add.i52, 2047
  br label %cleanup.i

cleanup.i:                                        ; preds = %if.end17.i, %if.then13.i, %if.then.i
  %cond28.i = phi i1 [ false, %if.then.i ], [ true, %if.end17.i ], [ false, %if.then13.i ]
  %first_tomb.2.i = phi i64 [ %first_tomb.053.i, %if.then.i ], [ %first_tomb.1.i, %if.end17.i ], [ %first_tomb.053.i, %if.then13.i ]
  %i.1.i = phi i64 [ %i.054.i, %if.then.i ], [ %and18.i, %if.end17.i ], [ %i.054.i, %if.then13.i ]
  %inc19.i = add nuw nsw i64 %probe.052.i, 1
  %cmp.i = icmp ult i64 %probe.052.i, 2047
  %or.cond = select i1 %cond28.i, i1 %cmp.i, i1 false
  br i1 %or.cond, label %for.body.i50, label %ht_put.exit, !llvm.loop !18

ht_put.exit:                                      ; preds = %cleanup.i
  %inc = add nuw nsw i64 %j.0116, 1
  %exitcond.not = icmp eq i64 %inc, %n
  br i1 %exitcond.not, label %for.cond4.preheader, label %for.body, !llvm.loop !19

for.cond.cleanup6:                                ; preds = %ht_del.exit, %for.cond4.preheader
  tail call fastcc void @ht_third_pass(ptr noundef nonnull %call.i, i64 noundef %n)
  %cmp14119 = icmp sgt i64 %n, 0
  br i1 %cmp14119, label %for.body16.lr.ph, label %for.cond.cleanup15

for.body16.lr.ph:                                 ; preds = %for.cond.cleanup6
  %2 = load i64, ptr %cap4.i, align 8, !tbaa !12
  %sub.i81 = add nsw i64 %2, -1
  %cmp.not25.i82 = icmp sgt i64 %2, 0
  br label %for.body16

for.body7:                                        ; preds = %for.cond4.preheader, %ht_del.exit
  %j3.0118 = phi i64 [ %add, %ht_del.exit ], [ 0, %for.cond4.preheader ]
  %mul.i54 = mul nsw i64 %j3.0118, 2654435761
  %add.i55 = add nuw nsw i64 %mul.i54, 7
  %shr.i.i60 = lshr i64 %add.i55, 30
  %xor.i.i61 = xor i64 %shr.i.i60, %add.i55
  %mul.i.i62 = mul i64 %xor.i.i61, -4658895280553007687
  %shr1.i.i63 = lshr i64 %mul.i.i62, 27
  %xor2.i.i64 = xor i64 %shr1.i.i63, %mul.i.i62
  %mul3.i.i65 = mul i64 %xor2.i.i64, -7723592293110705685
  %shr4.i.i66 = lshr i64 %mul3.i.i65, 31
  %xor5.i.i67 = xor i64 %shr4.i.i66, %mul3.i.i65
  %and.i68 = and i64 %xor5.i.i67, 2047
  br label %for.body.i70

for.body.i70:                                     ; preds = %cleanup.i73, %for.body7
  %probe.027.i = phi i64 [ 0, %for.body7 ], [ %inc.i76, %cleanup.i73 ]
  %i.026.i = phi i64 [ %and.i68, %for.body7 ], [ %i.1.i74, %cleanup.i73 ]
  %arrayidx.i71 = getelementptr inbounds i64, ptr %call1.i, i64 %i.026.i
  %3 = load i64, ptr %arrayidx.i71, align 8, !tbaa !14
  %cmp2.i = icmp eq i64 %3, -9223372036854775808
  br i1 %cmp2.i, label %cleanup.i73, label %if.end.i

if.end.i:                                         ; preds = %for.body.i70
  %cmp3.i = icmp eq i64 %3, %add.i55
  br i1 %cmp3.i, label %if.then4.i, label %if.end7.i

if.then4.i:                                       ; preds = %if.end.i
  store i64 -9223372036854775807, ptr %arrayidx.i71, align 8, !tbaa !14
  %4 = load i64, ptr %len.i, align 8, !tbaa !13
  %dec.i = add nsw i64 %4, -1
  store i64 %dec.i, ptr %len.i, align 8, !tbaa !13
  br label %cleanup.i73

if.end7.i:                                        ; preds = %if.end.i
  %add.i72 = add nsw i64 %i.026.i, 1
  %and8.i = and i64 %add.i72, 2047
  br label %cleanup.i73

cleanup.i73:                                      ; preds = %if.end7.i, %if.then4.i, %for.body.i70
  %i.1.i74 = phi i64 [ %i.026.i, %if.then4.i ], [ %and8.i, %if.end7.i ], [ %i.026.i, %for.body.i70 ]
  %cond13.i = phi i1 [ false, %if.then4.i ], [ true, %if.end7.i ], [ false, %for.body.i70 ]
  %inc.i76 = add nuw nsw i64 %probe.027.i, 1
  %cmp.not.i = icmp ult i64 %probe.027.i, 2047
  %or.cond112 = select i1 %cond13.i, i1 %cmp.not.i, i1 false
  br i1 %or.cond112, label %for.body.i70, label %ht_del.exit, !llvm.loop !20

ht_del.exit:                                      ; preds = %cleanup.i73
  %add = add nuw nsw i64 %j3.0118, 3
  %cmp5 = icmp slt i64 %add, %n
  br i1 %cmp5, label %for.body7, label %for.cond.cleanup6, !llvm.loop !21

for.cond.cleanup15.loopexit:                      ; preds = %cleanup8.i
  %5 = mul nsw i64 %checksum.1, 1000003
  br label %for.cond.cleanup15

for.cond.cleanup15:                               ; preds = %for.cond.cleanup15.loopexit, %for.cond.cleanup6
  %checksum.0.lcssa = phi i64 [ 0, %for.cond.cleanup6 ], [ %5, %for.cond.cleanup15.loopexit ]
  %6 = load i64, ptr %len.i, align 8, !tbaa !13
  %add25 = add nsw i64 %6, %checksum.0.lcssa
  %7 = load ptr, ptr %call.i, align 8, !tbaa !5
  tail call void @free(ptr noundef %7) #6
  %8 = load ptr, ptr %vals.i, align 8, !tbaa !11
  tail call void @free(ptr noundef %8) #6
  tail call void @free(ptr noundef %call.i) #6
  ret i64 %add25

for.body16:                                       ; preds = %for.body16.lr.ph, %cleanup8.i
  %j12.0121 = phi i64 [ 0, %for.body16.lr.ph ], [ %inc22, %cleanup8.i ]
  %checksum.0120 = phi i64 [ 0, %for.body16.lr.ph ], [ %checksum.1, %cleanup8.i ]
  %mul.i78 = mul nsw i64 %j12.0121, 2654435761
  %add.i79 = add nuw nsw i64 %mul.i78, 7
  br i1 %cmp.not25.i82, label %for.body.lr.ph.i83, label %cleanup8.i

for.body.lr.ph.i83:                               ; preds = %for.body16
  %shr.i.i84 = lshr i64 %add.i79, 30
  %xor.i.i85 = xor i64 %shr.i.i84, %add.i79
  %mul.i.i86 = mul i64 %xor.i.i85, -4658895280553007687
  %shr1.i.i87 = lshr i64 %mul.i.i86, 27
  %xor2.i.i88 = xor i64 %shr1.i.i87, %mul.i.i86
  %mul3.i.i89 = mul i64 %xor2.i.i88, -7723592293110705685
  %shr4.i.i90 = lshr i64 %mul3.i.i89, 31
  %xor5.i.i91 = xor i64 %shr4.i.i90, %mul3.i.i89
  %and.i92 = and i64 %sub.i81, %xor5.i.i91
  %9 = load ptr, ptr %call.i, align 8, !tbaa !5
  br label %for.body.i94

for.cond.i106:                                    ; preds = %cleanup.i103
  %inc.i107 = add nuw nsw i64 %probe.027.i96, 1
  %cmp.not.i108 = icmp slt i64 %inc.i107, %2
  %exitcond122.not = icmp eq i64 %inc.i107, %2
  br i1 %exitcond122.not, label %cleanup8.i, label %for.body.i94, !llvm.loop !22

for.body.i94:                                     ; preds = %for.cond.i106, %for.body.lr.ph.i83
  %found.0 = phi i64 [ 0, %for.body.lr.ph.i83 ], [ %found.1, %for.cond.i106 ]
  %cmp.not29.i = phi i1 [ true, %for.body.lr.ph.i83 ], [ %cmp.not.i108, %for.cond.i106 ]
  %retval.028.i95 = phi i64 [ undef, %for.body.lr.ph.i83 ], [ %retval.1.i105, %for.cond.i106 ]
  %probe.027.i96 = phi i64 [ 0, %for.body.lr.ph.i83 ], [ %inc.i107, %for.cond.i106 ]
  %i.026.i97 = phi i64 [ %and.i92, %for.body.lr.ph.i83 ], [ %i.1.i104, %for.cond.i106 ]
  %arrayidx.i98 = getelementptr inbounds i64, ptr %9, i64 %i.026.i97
  %10 = load i64, ptr %arrayidx.i98, align 8, !tbaa !14
  %cmp2.i99 = icmp eq i64 %10, -9223372036854775808
  br i1 %cmp2.i99, label %cleanup.i103, label %if.end.i100

if.end.i100:                                      ; preds = %for.body.i94
  %cmp3.i101 = icmp eq i64 %10, %add.i79
  br i1 %cmp3.i101, label %if.then4.i109, label %if.end6.i

if.then4.i109:                                    ; preds = %if.end.i100
  %11 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx5.i110 = getelementptr inbounds i64, ptr %11, i64 %i.026.i97
  %12 = load i64, ptr %arrayidx5.i110, align 8, !tbaa !14
  br label %cleanup.i103

if.end6.i:                                        ; preds = %if.end.i100
  %add.i102 = add nsw i64 %i.026.i97, 1
  %and7.i = and i64 %add.i102, %sub.i81
  br label %cleanup.i103

cleanup.i103:                                     ; preds = %for.body.i94, %if.end6.i, %if.then4.i109
  %found.1 = phi i64 [ 1, %if.then4.i109 ], [ %found.0, %if.end6.i ], [ 0, %for.body.i94 ]
  %i.1.i104 = phi i64 [ %i.026.i97, %if.then4.i109 ], [ %and7.i, %if.end6.i ], [ %i.026.i97, %for.body.i94 ]
  %cond12.i = phi i1 [ false, %if.then4.i109 ], [ true, %if.end6.i ], [ false, %for.body.i94 ]
  %retval.1.i105 = phi i64 [ %12, %if.then4.i109 ], [ %retval.028.i95, %if.end6.i ], [ 0, %for.body.i94 ]
  br i1 %cond12.i, label %for.cond.i106, label %cleanup8.i

cleanup8.i:                                       ; preds = %cleanup.i103, %for.cond.i106, %for.body16
  %found.2 = phi i64 [ 0, %for.body16 ], [ %found.1, %for.cond.i106 ], [ %found.1, %cleanup.i103 ]
  %cmp.not.lcssa.i = phi i1 [ %cmp.not25.i82, %for.body16 ], [ %cmp.not29.i, %cleanup.i103 ], [ %cmp.not.i108, %for.cond.i106 ]
  %retval.2.i = phi i64 [ undef, %for.body16 ], [ %retval.1.i105, %for.cond.i106 ], [ %retval.1.i105, %cleanup.i103 ]
  %spec.select113 = select i1 %cmp.not.lcssa.i, i64 %retval.2.i, i64 0
  %tobool.not114 = icmp ne i64 %found.2, 0
  %tobool.not.not = select i1 %cmp.not.lcssa.i, i1 %tobool.not114, i1 false
  %mul = mul nsw i64 %j12.0121, 131
  %xor = xor i64 %spec.select113, %mul
  %add20.neg = xor i64 %j12.0121, -1
  %xor.pn = select i1 %tobool.not.not, i64 %xor, i64 %add20.neg
  %checksum.1 = add i64 %xor.pn, %checksum.0120
  %inc22 = add nuw nsw i64 %j12.0121, 1
  %exitcond123.not = icmp eq i64 %inc22, %n
  br i1 %exitcond123.not, label %for.cond.cleanup15.loopexit, label %for.body16, !llvm.loop !23
}

; Function Attrs: nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none) uwtable
define internal fastcc void @ht_third_pass(ptr nocapture noundef %t, i64 noundef %n) unnamed_addr #1 {
entry:
  %cmp68 = icmp sgt i64 %n, 0
  br i1 %cmp68, label %for.body.lr.ph, label %for.cond.cleanup

for.body.lr.ph:                                   ; preds = %entry
  %cap.i = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 2
  %vals.i = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 1
  %len.i = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 3
  br label %for.body

for.cond.cleanup:                                 ; preds = %ht_put.exit, %entry
  %cmp3 = icmp sgt i64 %n, 1
  br i1 %cmp3, label %if.then, label %if.end

for.body:                                         ; preds = %for.body.lr.ph, %ht_put.exit
  %j.069 = phi i64 [ 0, %for.body.lr.ph ], [ %add2, %ht_put.exit ]
  %mul.i = mul nsw i64 %j.069, 2654435761
  %add.i = add nuw nsw i64 %mul.i, 7
  %xor.i = xor i64 %j.069, 23130
  %mul.i14 = mul nsw i64 %j.069, 3
  %add.i15 = add nuw nsw i64 %xor.i, %mul.i14
  %add = or disjoint i64 %add.i15, 1
  %0 = load i64, ptr %cap.i, align 8, !tbaa !12
  %sub.i = add nsw i64 %0, -1
  %cmp51.i = icmp sgt i64 %0, 0
  br i1 %cmp51.i, label %for.body.lr.ph.i, label %ht_put.exit

for.body.lr.ph.i:                                 ; preds = %for.body
  %shr.i.i = lshr i64 %add.i, 30
  %xor.i.i = xor i64 %shr.i.i, %add.i
  %mul.i.i = mul i64 %xor.i.i, -4658895280553007687
  %shr1.i.i = lshr i64 %mul.i.i, 27
  %xor2.i.i = xor i64 %shr1.i.i, %mul.i.i
  %mul3.i.i = mul i64 %xor2.i.i, -7723592293110705685
  %shr4.i.i = lshr i64 %mul3.i.i, 31
  %xor5.i.i = xor i64 %shr4.i.i, %mul3.i.i
  %and.i = and i64 %sub.i, %xor5.i.i
  %1 = load ptr, ptr %t, align 8, !tbaa !5
  br label %for.body.i

for.cond.i:                                       ; preds = %cleanup.i
  %inc19.i = add nuw nsw i64 %probe.052.i, 1
  %2 = load i64, ptr %cap.i, align 8, !tbaa !12
  %cmp.i = icmp slt i64 %inc19.i, %2
  br i1 %cmp.i, label %for.body.i, label %ht_put.exit, !llvm.loop !18

for.body.i:                                       ; preds = %for.cond.i, %for.body.lr.ph.i
  %i.054.i = phi i64 [ %and.i, %for.body.lr.ph.i ], [ %i.1.i, %for.cond.i ]
  %first_tomb.053.i = phi i64 [ -1, %for.body.lr.ph.i ], [ %first_tomb.2.i, %for.cond.i ]
  %probe.052.i = phi i64 [ 0, %for.body.lr.ph.i ], [ %inc19.i, %for.cond.i ]
  %arrayidx.i = getelementptr inbounds i64, ptr %1, i64 %i.054.i
  %3 = load i64, ptr %arrayidx.i, align 8, !tbaa !14
  switch i64 %3, label %if.else.i [
    i64 -9223372036854775808, label %if.then.i
    i64 -9223372036854775807, label %if.then8.i
  ]

if.then.i:                                        ; preds = %for.body.i
  %cmp350.i = icmp slt i64 %first_tomb.053.i, 0
  %cond.i = select i1 %cmp350.i, i64 %i.054.i, i64 %first_tomb.053.i
  %arrayidx5.i = getelementptr inbounds i64, ptr %1, i64 %cond.i
  store i64 %add.i, ptr %arrayidx5.i, align 8, !tbaa !14
  %4 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx6.i = getelementptr inbounds i64, ptr %4, i64 %cond.i
  store i64 %add, ptr %arrayidx6.i, align 8, !tbaa !14
  %5 = load i64, ptr %len.i, align 8, !tbaa !13
  %inc.i = add nsw i64 %5, 1
  store i64 %inc.i, ptr %len.i, align 8, !tbaa !13
  br label %cleanup.i

if.then8.i:                                       ; preds = %for.body.i
  %cmp9.i = icmp slt i64 %first_tomb.053.i, 0
  %spec.select.i = select i1 %cmp9.i, i64 %i.054.i, i64 %first_tomb.053.i
  br label %if.end17.i

if.else.i:                                        ; preds = %for.body.i
  %cmp12.i = icmp eq i64 %3, %add.i
  br i1 %cmp12.i, label %if.then13.i, label %if.end17.i

if.then13.i:                                      ; preds = %if.else.i
  %6 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx15.i = getelementptr inbounds i64, ptr %6, i64 %i.054.i
  store i64 %add, ptr %arrayidx15.i, align 8, !tbaa !14
  br label %cleanup.i

if.end17.i:                                       ; preds = %if.else.i, %if.then8.i
  %first_tomb.1.i = phi i64 [ %first_tomb.053.i, %if.else.i ], [ %spec.select.i, %if.then8.i ]
  %add.i16 = add nsw i64 %i.054.i, 1
  %and18.i = and i64 %add.i16, %sub.i
  br label %cleanup.i

cleanup.i:                                        ; preds = %if.end17.i, %if.then13.i, %if.then.i
  %cond28.i = phi i1 [ false, %if.then.i ], [ true, %if.end17.i ], [ false, %if.then13.i ]
  %first_tomb.2.i = phi i64 [ %first_tomb.053.i, %if.then.i ], [ %first_tomb.1.i, %if.end17.i ], [ %first_tomb.053.i, %if.then13.i ]
  %i.1.i = phi i64 [ %i.054.i, %if.then.i ], [ %and18.i, %if.end17.i ], [ %i.054.i, %if.then13.i ]
  br i1 %cond28.i, label %for.cond.i, label %ht_put.exit

ht_put.exit:                                      ; preds = %for.cond.i, %cleanup.i, %for.body
  %add2 = add nuw nsw i64 %j.069, 6
  %cmp = icmp slt i64 %add2, %n
  br i1 %cmp, label %for.body, label %for.cond.cleanup, !llvm.loop !24

if.then:                                          ; preds = %for.cond.cleanup
  %cap.i17 = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 2
  %7 = load i64, ptr %cap.i17, align 8, !tbaa !12
  %sub.i18 = add nsw i64 %7, -1
  %cmp51.i19 = icmp sgt i64 %7, 0
  br i1 %cmp51.i19, label %for.body.lr.ph.i20, label %if.end

for.body.lr.ph.i20:                               ; preds = %if.then
  %and.i21 = and i64 %sub.i18, -4911069518324041024
  %8 = load ptr, ptr %t, align 8, !tbaa !5
  %vals.i22 = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 1
  %len.i23 = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 3
  br label %for.body.i25

for.cond.i41:                                     ; preds = %cleanup.i37
  %inc19.i42 = add nuw nsw i64 %probe.052.i28, 1
  %9 = load i64, ptr %cap.i17, align 8, !tbaa !12
  %cmp.i43 = icmp slt i64 %inc19.i42, %9
  br i1 %cmp.i43, label %for.body.i25, label %if.end, !llvm.loop !18

for.body.i25:                                     ; preds = %for.cond.i41, %for.body.lr.ph.i20
  %i.054.i26 = phi i64 [ %and.i21, %for.body.lr.ph.i20 ], [ %i.1.i40, %for.cond.i41 ]
  %first_tomb.053.i27 = phi i64 [ -1, %for.body.lr.ph.i20 ], [ %first_tomb.2.i39, %for.cond.i41 ]
  %probe.052.i28 = phi i64 [ 0, %for.body.lr.ph.i20 ], [ %inc19.i42, %for.cond.i41 ]
  %arrayidx.i29 = getelementptr inbounds i64, ptr %8, i64 %i.054.i26
  %10 = load i64, ptr %arrayidx.i29, align 8, !tbaa !14
  switch i64 %10, label %if.end17.i33 [
    i64 -9223372036854775808, label %if.then.i44
    i64 -9223372036854775807, label %if.then8.i30
    i64 2654435768, label %if.then13.i52
  ]

if.then.i44:                                      ; preds = %for.body.i25
  %cmp350.i45 = icmp slt i64 %first_tomb.053.i27, 0
  %cond.i46 = select i1 %cmp350.i45, i64 %i.054.i26, i64 %first_tomb.053.i27
  %arrayidx5.i47 = getelementptr inbounds i64, ptr %8, i64 %cond.i46
  store i64 2654435768, ptr %arrayidx5.i47, align 8, !tbaa !14
  %11 = load ptr, ptr %vals.i22, align 8, !tbaa !11
  %arrayidx6.i48 = getelementptr inbounds i64, ptr %11, i64 %cond.i46
  store i64 23135, ptr %arrayidx6.i48, align 8, !tbaa !14
  %12 = load i64, ptr %len.i23, align 8, !tbaa !13
  %inc.i49 = add nsw i64 %12, 1
  store i64 %inc.i49, ptr %len.i23, align 8, !tbaa !13
  br label %cleanup.i37

if.then8.i30:                                     ; preds = %for.body.i25
  %cmp9.i31 = icmp slt i64 %first_tomb.053.i27, 0
  %spec.select.i32 = select i1 %cmp9.i31, i64 %i.054.i26, i64 %first_tomb.053.i27
  br label %if.end17.i33

if.then13.i52:                                    ; preds = %for.body.i25
  %13 = load ptr, ptr %vals.i22, align 8, !tbaa !11
  %arrayidx15.i53 = getelementptr inbounds i64, ptr %13, i64 %i.054.i26
  store i64 23135, ptr %arrayidx15.i53, align 8, !tbaa !14
  br label %cleanup.i37

if.end17.i33:                                     ; preds = %for.body.i25, %if.then8.i30
  %first_tomb.1.i34 = phi i64 [ %spec.select.i32, %if.then8.i30 ], [ %first_tomb.053.i27, %for.body.i25 ]
  %add.i35 = add nsw i64 %i.054.i26, 1
  %and18.i36 = and i64 %add.i35, %sub.i18
  br label %cleanup.i37

cleanup.i37:                                      ; preds = %if.end17.i33, %if.then13.i52, %if.then.i44
  %cond28.i38 = phi i1 [ false, %if.then.i44 ], [ true, %if.end17.i33 ], [ false, %if.then13.i52 ]
  %first_tomb.2.i39 = phi i64 [ %first_tomb.053.i27, %if.then.i44 ], [ %first_tomb.1.i34, %if.end17.i33 ], [ %first_tomb.053.i27, %if.then13.i52 ]
  %i.1.i40 = phi i64 [ %i.054.i26, %if.then.i44 ], [ %and18.i36, %if.end17.i33 ], [ %i.054.i26, %if.then13.i52 ]
  br i1 %cond28.i38, label %for.cond.i41, label %if.end

if.end:                                           ; preds = %cleanup.i37, %for.cond.i41, %if.then, %for.cond.cleanup
  %cap.i55 = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 2
  %14 = load i64, ptr %cap.i55, align 8, !tbaa !12
  %sub.i56 = add nsw i64 %14, -1
  %cmp.not25.i = icmp sgt i64 %14, 0
  br i1 %cmp.not25.i, label %for.body.lr.ph.i58, label %ht_del.exit

for.body.lr.ph.i58:                               ; preds = %if.end
  %and.i59 = and i64 %sub.i56, 2185194620014831856
  %15 = load ptr, ptr %t, align 8, !tbaa !5
  %len.i60 = getelementptr inbounds %struct.ht, ptr %t, i64 0, i32 3
  br label %for.body.i61

for.cond.i66:                                     ; preds = %cleanup.i64
  %inc.i67 = add nuw nsw i64 %probe.027.i, 1
  %16 = load i64, ptr %cap.i55, align 8, !tbaa !12
  %cmp.not.i = icmp slt i64 %inc.i67, %16
  br i1 %cmp.not.i, label %for.body.i61, label %ht_del.exit, !llvm.loop !20

for.body.i61:                                     ; preds = %for.cond.i66, %for.body.lr.ph.i58
  %probe.027.i = phi i64 [ 0, %for.body.lr.ph.i58 ], [ %inc.i67, %for.cond.i66 ]
  %i.026.i = phi i64 [ %and.i59, %for.body.lr.ph.i58 ], [ %i.1.i65, %for.cond.i66 ]
  %arrayidx.i62 = getelementptr inbounds i64, ptr %15, i64 %i.026.i
  %17 = load i64, ptr %arrayidx.i62, align 8, !tbaa !14
  switch i64 %17, label %if.end7.i [
    i64 -9223372036854775808, label %cleanup.i64
    i64 3, label %if.then4.i
  ]

if.then4.i:                                       ; preds = %for.body.i61
  store i64 -9223372036854775807, ptr %arrayidx.i62, align 8, !tbaa !14
  %18 = load i64, ptr %len.i60, align 8, !tbaa !13
  %dec.i = add nsw i64 %18, -1
  store i64 %dec.i, ptr %len.i60, align 8, !tbaa !13
  br label %cleanup.i64

if.end7.i:                                        ; preds = %for.body.i61
  %add.i63 = add nsw i64 %i.026.i, 1
  %and8.i = and i64 %add.i63, %sub.i56
  br label %cleanup.i64

cleanup.i64:                                      ; preds = %for.body.i61, %if.end7.i, %if.then4.i
  %i.1.i65 = phi i64 [ %i.026.i, %if.then4.i ], [ %and8.i, %if.end7.i ], [ %i.026.i, %for.body.i61 ]
  %cond13.i = phi i1 [ false, %if.then4.i ], [ true, %if.end7.i ], [ false, %for.body.i61 ]
  br i1 %cond13.i, label %for.cond.i66, label %ht_del.exit

ht_del.exit:                                      ; preds = %for.cond.i66, %cleanup.i64, %if.end
  ret void
}

; Function Attrs: nounwind uwtable
define dso_local i64 @ht_demo_grow(i64 noundef %n) local_unnamed_addr #0 {
entry:
  %call.i = tail call noalias dereferenceable_or_null(32) ptr @malloc(i64 noundef 32) #5
  %call1.i = tail call noalias dereferenceable_or_null(32) ptr @malloc(i64 noundef 32) #5
  store ptr %call1.i, ptr %call.i, align 8, !tbaa !5
  %call3.i = tail call noalias dereferenceable_or_null(32) ptr @malloc(i64 noundef 32) #5
  %vals.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 1
  store ptr %call3.i, ptr %vals.i, align 8, !tbaa !11
  %cap4.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 2
  store i64 4, ptr %cap4.i, align 8, !tbaa !12
  %len.i = getelementptr inbounds %struct.ht, ptr %call.i, i64 0, i32 3
  store i64 0, ptr %len.i, align 8, !tbaa !13
  tail call void @llvm.memset.p0.i64(ptr noundef nonnull align 8 dereferenceable(32) %call3.i, i8 0, i64 32, i1 false), !tbaa !14
  br label %for.body.i

for.body.i:                                       ; preds = %for.body.i, %entry
  %i.021.i = phi i64 [ %inc.i, %for.body.i ], [ 0, %entry ]
  %arrayidx.i = getelementptr inbounds i64, ptr %call1.i, i64 %i.021.i
  store i64 -9223372036854775808, ptr %arrayidx.i, align 8, !tbaa !14
  %inc.i = add nuw nsw i64 %i.021.i, 1
  %exitcond.not.i = icmp eq i64 %inc.i, 4
  br i1 %exitcond.not.i, label %for.cond.preheader, label %for.body.i, !llvm.loop !15

for.cond.preheader:                               ; preds = %for.body.i
  %cmp143 = icmp sgt i64 %n, 0
  br i1 %cmp143, label %for.body.lr.ph, label %for.cond6.preheader

for.body.lr.ph:                                   ; preds = %for.cond.preheader
  %len.i.promoted = load i64, ptr %len.i, align 8, !tbaa !13
  %cap4.i.promoted = load i64, ptr %cap4.i, align 8, !tbaa !12
  br label %for.body

for.cond.for.cond6.preheader_crit_edge:           ; preds = %ht_put.exit
  store i64 %22, ptr %len.i, align 8, !tbaa !13
  store i64 %14, ptr %cap4.i, align 8, !tbaa !12
  br label %for.cond6.preheader

for.cond6.preheader:                              ; preds = %for.cond.for.cond6.preheader_crit_edge, %for.cond.preheader
  %cmp7149 = icmp sgt i64 %n, 0
  br i1 %cmp7149, label %for.body9.lr.ph, label %for.cond.cleanup8

for.body9.lr.ph:                                  ; preds = %for.cond6.preheader
  %0 = load i64, ptr %cap4.i, align 8, !tbaa !12
  %sub.i83 = add nsw i64 %0, -1
  %cmp.not25.i = icmp sgt i64 %0, 0
  br label %for.body9

for.body:                                         ; preds = %for.body.lr.ph, %ht_put.exit
  %1 = phi i64 [ %cap4.i.promoted, %for.body.lr.ph ], [ %14, %ht_put.exit ]
  %2 = phi i64 [ %len.i.promoted, %for.body.lr.ph ], [ %22, %ht_put.exit ]
  %j.0144 = phi i64 [ 0, %for.body.lr.ph ], [ %inc, %ht_put.exit ]
  %3 = mul i64 %2, 10
  %mul = add i64 %3, 10
  %mul1 = mul nsw i64 %1, 7
  %cmp2 = icmp sgt i64 %mul, %mul1
  br i1 %cmp2, label %if.then, label %if.end

if.then:                                          ; preds = %for.body
  %4 = load ptr, ptr %call.i, align 8, !tbaa !5
  %5 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %shl.i = shl i64 %1, 1
  %mul.i = shl i64 %1, 4
  %call.i61 = tail call noalias ptr @malloc(i64 noundef %mul.i) #5
  store ptr %call.i61, ptr %call.i, align 8, !tbaa !5
  %call3.i62 = tail call noalias ptr @malloc(i64 noundef %mul.i) #5
  store ptr %call3.i62, ptr %vals.i, align 8, !tbaa !11
  %cmp44.i = icmp sgt i64 %shl.i, 0
  br i1 %cmp44.i, label %for.body.preheader.i, label %for.cond10.preheader.i

for.body.preheader.i:                             ; preds = %if.then
  tail call void @llvm.memset.p0.i64(ptr align 8 %call3.i62, i8 0, i64 %mul.i, i1 false), !tbaa !14
  br label %for.body.i64

for.cond10.preheader.i:                           ; preds = %for.body.i64, %if.then
  %cmp1146.i = icmp sgt i64 %1, 0
  br i1 %cmp1146.i, label %for.body13.i.preheader, label %ht_grow.exit

for.body13.i.preheader:                           ; preds = %for.cond10.preheader.i
  %sub.i.i = add nsw i64 %shl.i, -1
  br label %for.body13.i

for.body.i64:                                     ; preds = %for.body.i64, %for.body.preheader.i
  %i.045.i = phi i64 [ %inc.i66, %for.body.i64 ], [ 0, %for.body.preheader.i ]
  %arrayidx.i65 = getelementptr inbounds i64, ptr %call.i61, i64 %i.045.i
  store i64 -9223372036854775808, ptr %arrayidx.i65, align 8, !tbaa !14
  %inc.i66 = add nuw nsw i64 %i.045.i, 1
  %exitcond.not.i67 = icmp eq i64 %inc.i66, %shl.i
  br i1 %exitcond.not.i67, label %for.cond10.preheader.i, label %for.body.i64, !llvm.loop !25

for.body13.i:                                     ; preds = %for.body13.i.preheader, %if.end.i
  %6 = phi i64 [ %12, %if.end.i ], [ 0, %for.body13.i.preheader ]
  %i9.047.i = phi i64 [ %inc19.i, %if.end.i ], [ 0, %for.body13.i.preheader ]
  %arrayidx14.i = getelementptr inbounds i64, ptr %4, i64 %i9.047.i
  %7 = load i64, ptr %arrayidx14.i, align 8, !tbaa !14
  %or.cond.i = icmp sgt i64 %7, -9223372036854775807
  br i1 %or.cond.i, label %if.then.i, label %if.end.i

if.then.i:                                        ; preds = %for.body13.i
  %arrayidx17.i = getelementptr inbounds i64, ptr %5, i64 %i9.047.i
  %8 = load i64, ptr %arrayidx17.i, align 8, !tbaa !14
  br i1 %cmp44.i, label %for.body.lr.ph.i.i, label %if.end.i

for.body.lr.ph.i.i:                               ; preds = %if.then.i
  %shr.i.i.i = lshr i64 %7, 30
  %xor.i.i.i = xor i64 %shr.i.i.i, %7
  %mul.i.i.i = mul i64 %xor.i.i.i, -4658895280553007687
  %shr1.i.i.i = lshr i64 %mul.i.i.i, 27
  %xor2.i.i.i = xor i64 %shr1.i.i.i, %mul.i.i.i
  %mul3.i.i.i = mul i64 %xor2.i.i.i, -7723592293110705685
  %shr4.i.i.i = lshr i64 %mul3.i.i.i, 31
  %xor5.i.i.i = xor i64 %shr4.i.i.i, %mul3.i.i.i
  %and.i.i = and i64 %xor5.i.i.i, %sub.i.i
  br label %for.body.i.i

for.body.i.i:                                     ; preds = %cleanup.i.i, %for.body.lr.ph.i.i
  %9 = phi i64 [ %6, %for.body.lr.ph.i.i ], [ %11, %cleanup.i.i ]
  %i.054.i.i = phi i64 [ %and.i.i, %for.body.lr.ph.i.i ], [ %i.1.i.i, %cleanup.i.i ]
  %first_tomb.053.i.i = phi i64 [ -1, %for.body.lr.ph.i.i ], [ %first_tomb.2.i.i, %cleanup.i.i ]
  %probe.052.i.i = phi i64 [ 0, %for.body.lr.ph.i.i ], [ %inc19.i.i, %cleanup.i.i ]
  %arrayidx.i.i = getelementptr inbounds i64, ptr %call.i61, i64 %i.054.i.i
  %10 = load i64, ptr %arrayidx.i.i, align 8, !tbaa !14
  switch i64 %10, label %if.else.i.i [
    i64 -9223372036854775808, label %if.then.i.i
    i64 -9223372036854775807, label %if.then8.i.i
  ]

if.then.i.i:                                      ; preds = %for.body.i.i
  %cmp350.i.i = icmp slt i64 %first_tomb.053.i.i, 0
  %cond.i.i = select i1 %cmp350.i.i, i64 %i.054.i.i, i64 %first_tomb.053.i.i
  %arrayidx5.i.i = getelementptr inbounds i64, ptr %call.i61, i64 %cond.i.i
  store i64 %7, ptr %arrayidx5.i.i, align 8, !tbaa !14
  %arrayidx6.i.i = getelementptr inbounds i64, ptr %call3.i62, i64 %cond.i.i
  store i64 %8, ptr %arrayidx6.i.i, align 8, !tbaa !14
  %inc.i.i = add nsw i64 %9, 1
  br label %cleanup.i.i

if.then8.i.i:                                     ; preds = %for.body.i.i
  %cmp9.i.i = icmp slt i64 %first_tomb.053.i.i, 0
  %spec.select.i.i = select i1 %cmp9.i.i, i64 %i.054.i.i, i64 %first_tomb.053.i.i
  br label %if.end17.i.i

if.else.i.i:                                      ; preds = %for.body.i.i
  %cmp12.i.i = icmp eq i64 %10, %7
  br i1 %cmp12.i.i, label %if.then13.i.i, label %if.end17.i.i

if.then13.i.i:                                    ; preds = %if.else.i.i
  %arrayidx15.i.i = getelementptr inbounds i64, ptr %call3.i62, i64 %i.054.i.i
  store i64 %8, ptr %arrayidx15.i.i, align 8, !tbaa !14
  br label %cleanup.i.i

if.end17.i.i:                                     ; preds = %if.else.i.i, %if.then8.i.i
  %first_tomb.1.i.i = phi i64 [ %first_tomb.053.i.i, %if.else.i.i ], [ %spec.select.i.i, %if.then8.i.i ]
  %add.i.i = add nsw i64 %i.054.i.i, 1
  %and18.i.i = and i64 %add.i.i, %sub.i.i
  br label %cleanup.i.i

cleanup.i.i:                                      ; preds = %if.end17.i.i, %if.then13.i.i, %if.then.i.i
  %11 = phi i64 [ %inc.i.i, %if.then.i.i ], [ %9, %if.end17.i.i ], [ %9, %if.then13.i.i ]
  %cond28.i.i = phi i1 [ false, %if.then.i.i ], [ true, %if.end17.i.i ], [ false, %if.then13.i.i ]
  %first_tomb.2.i.i = phi i64 [ %first_tomb.053.i.i, %if.then.i.i ], [ %first_tomb.1.i.i, %if.end17.i.i ], [ %first_tomb.053.i.i, %if.then13.i.i ]
  %i.1.i.i = phi i64 [ %i.054.i.i, %if.then.i.i ], [ %and18.i.i, %if.end17.i.i ], [ %i.054.i.i, %if.then13.i.i ]
  %inc19.i.i = add nuw nsw i64 %probe.052.i.i, 1
  %cmp.i.i = icmp slt i64 %inc19.i.i, %shl.i
  %or.cond = select i1 %cond28.i.i, i1 %cmp.i.i, i1 false
  br i1 %or.cond, label %for.body.i.i, label %if.end.i, !llvm.loop !18

if.end.i:                                         ; preds = %cleanup.i.i, %if.then.i, %for.body13.i
  %12 = phi i64 [ %6, %if.then.i ], [ %6, %for.body13.i ], [ %11, %cleanup.i.i ]
  %inc19.i = add nuw nsw i64 %i9.047.i, 1
  %exitcond48.not.i = icmp eq i64 %inc19.i, %1
  br i1 %exitcond48.not.i, label %ht_grow.exit, label %for.body13.i, !llvm.loop !26

ht_grow.exit:                                     ; preds = %if.end.i, %for.cond10.preheader.i
  %13 = phi i64 [ 0, %for.cond10.preheader.i ], [ %12, %if.end.i ]
  tail call void @free(ptr noundef %4) #6
  tail call void @free(ptr noundef %5) #6
  br label %if.end

if.end:                                           ; preds = %ht_grow.exit, %for.body
  %14 = phi i64 [ %shl.i, %ht_grow.exit ], [ %1, %for.body ]
  %15 = phi i64 [ %13, %ht_grow.exit ], [ %2, %for.body ]
  %mul.i68 = mul nsw i64 %j.0144, 2654435761
  %add.i = add nuw nsw i64 %mul.i68, 7
  %xor.i = xor i64 %j.0144, 23130
  %mul.i69 = mul nsw i64 %j.0144, 3
  %add.i70 = add nuw nsw i64 %xor.i, %mul.i69
  %sub.i = add nsw i64 %14, -1
  %cmp51.i = icmp sgt i64 %14, 0
  br i1 %cmp51.i, label %for.body.lr.ph.i, label %ht_put.exit

for.body.lr.ph.i:                                 ; preds = %if.end
  %shr.i.i = lshr i64 %add.i, 30
  %xor.i.i = xor i64 %shr.i.i, %add.i
  %mul.i.i = mul i64 %xor.i.i, -4658895280553007687
  %shr1.i.i = lshr i64 %mul.i.i, 27
  %xor2.i.i = xor i64 %shr1.i.i, %mul.i.i
  %mul3.i.i = mul i64 %xor2.i.i, -7723592293110705685
  %shr4.i.i = lshr i64 %mul3.i.i, 31
  %xor5.i.i = xor i64 %shr4.i.i, %mul3.i.i
  %and.i = and i64 %sub.i, %xor5.i.i
  %16 = load ptr, ptr %call.i, align 8, !tbaa !5
  br label %for.body.i74

for.body.i74:                                     ; preds = %cleanup.i, %for.body.lr.ph.i
  %17 = phi i64 [ %15, %for.body.lr.ph.i ], [ %21, %cleanup.i ]
  %i.054.i = phi i64 [ %and.i, %for.body.lr.ph.i ], [ %i.1.i, %cleanup.i ]
  %first_tomb.053.i = phi i64 [ -1, %for.body.lr.ph.i ], [ %first_tomb.2.i, %cleanup.i ]
  %probe.052.i = phi i64 [ 0, %for.body.lr.ph.i ], [ %inc19.i77, %cleanup.i ]
  %arrayidx.i75 = getelementptr inbounds i64, ptr %16, i64 %i.054.i
  %18 = load i64, ptr %arrayidx.i75, align 8, !tbaa !14
  switch i64 %18, label %if.else.i [
    i64 -9223372036854775808, label %if.then.i78
    i64 -9223372036854775807, label %if.then8.i
  ]

if.then.i78:                                      ; preds = %for.body.i74
  %cmp350.i = icmp slt i64 %first_tomb.053.i, 0
  %cond.i = select i1 %cmp350.i, i64 %i.054.i, i64 %first_tomb.053.i
  %arrayidx5.i = getelementptr inbounds i64, ptr %16, i64 %cond.i
  store i64 %add.i, ptr %arrayidx5.i, align 8, !tbaa !14
  %19 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx6.i = getelementptr inbounds i64, ptr %19, i64 %cond.i
  store i64 %add.i70, ptr %arrayidx6.i, align 8, !tbaa !14
  %inc.i79 = add nsw i64 %17, 1
  br label %cleanup.i

if.then8.i:                                       ; preds = %for.body.i74
  %cmp9.i = icmp slt i64 %first_tomb.053.i, 0
  %spec.select.i = select i1 %cmp9.i, i64 %i.054.i, i64 %first_tomb.053.i
  br label %if.end17.i

if.else.i:                                        ; preds = %for.body.i74
  %cmp12.i = icmp eq i64 %18, %add.i
  br i1 %cmp12.i, label %if.then13.i, label %if.end17.i

if.then13.i:                                      ; preds = %if.else.i
  %20 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx15.i = getelementptr inbounds i64, ptr %20, i64 %i.054.i
  store i64 %add.i70, ptr %arrayidx15.i, align 8, !tbaa !14
  br label %cleanup.i

if.end17.i:                                       ; preds = %if.else.i, %if.then8.i
  %first_tomb.1.i = phi i64 [ %first_tomb.053.i, %if.else.i ], [ %spec.select.i, %if.then8.i ]
  %add.i76 = add nsw i64 %i.054.i, 1
  %and18.i = and i64 %add.i76, %sub.i
  br label %cleanup.i

cleanup.i:                                        ; preds = %if.end17.i, %if.then13.i, %if.then.i78
  %21 = phi i64 [ %inc.i79, %if.then.i78 ], [ %17, %if.end17.i ], [ %17, %if.then13.i ]
  %cond28.i = phi i1 [ false, %if.then.i78 ], [ true, %if.end17.i ], [ false, %if.then13.i ]
  %first_tomb.2.i = phi i64 [ %first_tomb.053.i, %if.then.i78 ], [ %first_tomb.1.i, %if.end17.i ], [ %first_tomb.053.i, %if.then13.i ]
  %i.1.i = phi i64 [ %i.054.i, %if.then.i78 ], [ %and18.i, %if.end17.i ], [ %i.054.i, %if.then13.i ]
  %inc19.i77 = add nuw nsw i64 %probe.052.i, 1
  %cmp.i = icmp slt i64 %inc19.i77, %14
  %or.cond139 = select i1 %cond28.i, i1 %cmp.i, i1 false
  br i1 %or.cond139, label %for.body.i74, label %ht_put.exit, !llvm.loop !18

ht_put.exit:                                      ; preds = %cleanup.i, %if.end
  %22 = phi i64 [ %15, %if.end ], [ %21, %cleanup.i ]
  %inc = add nuw nsw i64 %j.0144, 1
  %exitcond.not = icmp eq i64 %inc, %n
  br i1 %exitcond.not, label %for.cond.for.cond6.preheader_crit_edge, label %for.body, !llvm.loop !27

for.cond.cleanup8:                                ; preds = %ht_del.exit, %for.cond6.preheader
  tail call fastcc void @ht_third_pass(ptr noundef nonnull %call.i, i64 noundef %n)
  %cmp17151 = icmp sgt i64 %n, 0
  br i1 %cmp17151, label %for.body19.lr.ph, label %for.cond.cleanup18

for.body19.lr.ph:                                 ; preds = %for.cond.cleanup8
  %23 = load i64, ptr %cap4.i, align 8, !tbaa !12
  %sub.i108 = add nsw i64 %23, -1
  %cmp.not25.i109 = icmp sgt i64 %23, 0
  br label %for.body19

for.body9:                                        ; preds = %for.body9.lr.ph, %ht_del.exit
  %j5.0150 = phi i64 [ 0, %for.body9.lr.ph ], [ %add13, %ht_del.exit ]
  %mul.i80 = mul nsw i64 %j5.0150, 2654435761
  %add.i81 = add nuw nsw i64 %mul.i80, 7
  br i1 %cmp.not25.i, label %for.body.lr.ph.i85, label %ht_del.exit

for.body.lr.ph.i85:                               ; preds = %for.body9
  %shr.i.i86 = lshr i64 %add.i81, 30
  %xor.i.i87 = xor i64 %shr.i.i86, %add.i81
  %mul.i.i88 = mul i64 %xor.i.i87, -4658895280553007687
  %shr1.i.i89 = lshr i64 %mul.i.i88, 27
  %xor2.i.i90 = xor i64 %shr1.i.i89, %mul.i.i88
  %mul3.i.i91 = mul i64 %xor2.i.i90, -7723592293110705685
  %shr4.i.i92 = lshr i64 %mul3.i.i91, 31
  %xor5.i.i93 = xor i64 %shr4.i.i92, %mul3.i.i91
  %and.i94 = and i64 %sub.i83, %xor5.i.i93
  %24 = load ptr, ptr %call.i, align 8, !tbaa !5
  br label %for.body.i96

for.body.i96:                                     ; preds = %cleanup.i100, %for.body.lr.ph.i85
  %probe.027.i = phi i64 [ 0, %for.body.lr.ph.i85 ], [ %inc.i103, %cleanup.i100 ]
  %i.026.i = phi i64 [ %and.i94, %for.body.lr.ph.i85 ], [ %i.1.i101, %cleanup.i100 ]
  %arrayidx.i97 = getelementptr inbounds i64, ptr %24, i64 %i.026.i
  %25 = load i64, ptr %arrayidx.i97, align 8, !tbaa !14
  %cmp2.i = icmp eq i64 %25, -9223372036854775808
  br i1 %cmp2.i, label %cleanup.i100, label %if.end.i98

if.end.i98:                                       ; preds = %for.body.i96
  %cmp3.i = icmp eq i64 %25, %add.i81
  br i1 %cmp3.i, label %if.then4.i, label %if.end7.i

if.then4.i:                                       ; preds = %if.end.i98
  store i64 -9223372036854775807, ptr %arrayidx.i97, align 8, !tbaa !14
  %26 = load i64, ptr %len.i, align 8, !tbaa !13
  %dec.i = add nsw i64 %26, -1
  store i64 %dec.i, ptr %len.i, align 8, !tbaa !13
  br label %cleanup.i100

if.end7.i:                                        ; preds = %if.end.i98
  %add.i99 = add nsw i64 %i.026.i, 1
  %and8.i = and i64 %add.i99, %sub.i83
  br label %cleanup.i100

cleanup.i100:                                     ; preds = %if.end7.i, %if.then4.i, %for.body.i96
  %i.1.i101 = phi i64 [ %i.026.i, %if.then4.i ], [ %and8.i, %if.end7.i ], [ %i.026.i, %for.body.i96 ]
  %cond13.i = phi i1 [ false, %if.then4.i ], [ true, %if.end7.i ], [ false, %for.body.i96 ]
  %inc.i103 = add nuw nsw i64 %probe.027.i, 1
  %cmp.not.i = icmp slt i64 %inc.i103, %0
  %or.cond140 = select i1 %cond13.i, i1 %cmp.not.i, i1 false
  br i1 %or.cond140, label %for.body.i96, label %ht_del.exit, !llvm.loop !20

ht_del.exit:                                      ; preds = %cleanup.i100, %for.body9
  %add13 = add nuw nsw i64 %j5.0150, 3
  %cmp7 = icmp slt i64 %add13, %n
  br i1 %cmp7, label %for.body9, label %for.cond.cleanup8, !llvm.loop !28

for.cond.cleanup18.loopexit:                      ; preds = %cleanup8.i
  %27 = mul nsw i64 %checksum.1, 1000003
  br label %for.cond.cleanup18

for.cond.cleanup18:                               ; preds = %for.cond.cleanup18.loopexit, %for.cond.cleanup8
  %checksum.0.lcssa = phi i64 [ 0, %for.cond.cleanup8 ], [ %27, %for.cond.cleanup18.loopexit ]
  %28 = load i64, ptr %len.i, align 8, !tbaa !13
  %mul32 = mul nsw i64 %28, 7
  %add33 = add nsw i64 %mul32, %checksum.0.lcssa
  %29 = load i64, ptr %cap4.i, align 8, !tbaa !12
  %add35 = add nsw i64 %add33, %29
  %30 = load ptr, ptr %call.i, align 8, !tbaa !5
  tail call void @free(ptr noundef %30) #6
  %31 = load ptr, ptr %vals.i, align 8, !tbaa !11
  tail call void @free(ptr noundef %31) #6
  tail call void @free(ptr noundef %call.i) #6
  ret i64 %add35

for.body19:                                       ; preds = %for.body19.lr.ph, %cleanup8.i
  %j15.0153 = phi i64 [ 0, %for.body19.lr.ph ], [ %inc28, %cleanup8.i ]
  %checksum.0152 = phi i64 [ 0, %for.body19.lr.ph ], [ %checksum.1, %cleanup8.i ]
  %mul.i105 = mul nsw i64 %j15.0153, 2654435761
  %add.i106 = add nuw nsw i64 %mul.i105, 7
  br i1 %cmp.not25.i109, label %for.body.lr.ph.i110, label %cleanup8.i

for.body.lr.ph.i110:                              ; preds = %for.body19
  %shr.i.i111 = lshr i64 %add.i106, 30
  %xor.i.i112 = xor i64 %shr.i.i111, %add.i106
  %mul.i.i113 = mul i64 %xor.i.i112, -4658895280553007687
  %shr1.i.i114 = lshr i64 %mul.i.i113, 27
  %xor2.i.i115 = xor i64 %shr1.i.i114, %mul.i.i113
  %mul3.i.i116 = mul i64 %xor2.i.i115, -7723592293110705685
  %shr4.i.i117 = lshr i64 %mul3.i.i116, 31
  %xor5.i.i118 = xor i64 %shr4.i.i117, %mul3.i.i116
  %and.i119 = and i64 %sub.i108, %xor5.i.i118
  %32 = load ptr, ptr %call.i, align 8, !tbaa !5
  br label %for.body.i121

for.cond.i133:                                    ; preds = %cleanup.i130
  %inc.i134 = add nuw nsw i64 %probe.027.i123, 1
  %cmp.not.i135 = icmp slt i64 %inc.i134, %23
  %exitcond158.not = icmp eq i64 %inc.i134, %23
  br i1 %exitcond158.not, label %cleanup8.i, label %for.body.i121, !llvm.loop !22

for.body.i121:                                    ; preds = %for.cond.i133, %for.body.lr.ph.i110
  %found.0 = phi i64 [ 0, %for.body.lr.ph.i110 ], [ %found.1, %for.cond.i133 ]
  %cmp.not29.i = phi i1 [ true, %for.body.lr.ph.i110 ], [ %cmp.not.i135, %for.cond.i133 ]
  %retval.028.i122 = phi i64 [ undef, %for.body.lr.ph.i110 ], [ %retval.1.i132, %for.cond.i133 ]
  %probe.027.i123 = phi i64 [ 0, %for.body.lr.ph.i110 ], [ %inc.i134, %for.cond.i133 ]
  %i.026.i124 = phi i64 [ %and.i119, %for.body.lr.ph.i110 ], [ %i.1.i131, %for.cond.i133 ]
  %arrayidx.i125 = getelementptr inbounds i64, ptr %32, i64 %i.026.i124
  %33 = load i64, ptr %arrayidx.i125, align 8, !tbaa !14
  %cmp2.i126 = icmp eq i64 %33, -9223372036854775808
  br i1 %cmp2.i126, label %cleanup.i130, label %if.end.i127

if.end.i127:                                      ; preds = %for.body.i121
  %cmp3.i128 = icmp eq i64 %33, %add.i106
  br i1 %cmp3.i128, label %if.then4.i136, label %if.end6.i

if.then4.i136:                                    ; preds = %if.end.i127
  %34 = load ptr, ptr %vals.i, align 8, !tbaa !11
  %arrayidx5.i137 = getelementptr inbounds i64, ptr %34, i64 %i.026.i124
  %35 = load i64, ptr %arrayidx5.i137, align 8, !tbaa !14
  br label %cleanup.i130

if.end6.i:                                        ; preds = %if.end.i127
  %add.i129 = add nsw i64 %i.026.i124, 1
  %and7.i = and i64 %add.i129, %sub.i108
  br label %cleanup.i130

cleanup.i130:                                     ; preds = %for.body.i121, %if.end6.i, %if.then4.i136
  %found.1 = phi i64 [ 1, %if.then4.i136 ], [ %found.0, %if.end6.i ], [ 0, %for.body.i121 ]
  %i.1.i131 = phi i64 [ %i.026.i124, %if.then4.i136 ], [ %and7.i, %if.end6.i ], [ %i.026.i124, %for.body.i121 ]
  %cond12.i = phi i1 [ false, %if.then4.i136 ], [ true, %if.end6.i ], [ false, %for.body.i121 ]
  %retval.1.i132 = phi i64 [ %35, %if.then4.i136 ], [ %retval.028.i122, %if.end6.i ], [ 0, %for.body.i121 ]
  br i1 %cond12.i, label %for.cond.i133, label %cleanup8.i

cleanup8.i:                                       ; preds = %cleanup.i130, %for.cond.i133, %for.body19
  %found.2 = phi i64 [ 0, %for.body19 ], [ %found.1, %for.cond.i133 ], [ %found.1, %cleanup.i130 ]
  %cmp.not.lcssa.i = phi i1 [ %cmp.not25.i109, %for.body19 ], [ %cmp.not29.i, %cleanup.i130 ], [ %cmp.not.i135, %for.cond.i133 ]
  %retval.2.i = phi i64 [ undef, %for.body19 ], [ %retval.1.i132, %for.cond.i133 ], [ %retval.1.i132, %cleanup.i130 ]
  %spec.select141 = select i1 %cmp.not.lcssa.i, i64 %retval.2.i, i64 0
  %tobool.not142 = icmp ne i64 %found.2, 0
  %tobool.not.not = select i1 %cmp.not.lcssa.i, i1 %tobool.not142, i1 false
  %mul23 = mul nsw i64 %j15.0153, 131
  %xor = xor i64 %spec.select141, %mul23
  %add25.neg = xor i64 %j15.0153, -1
  %xor.pn = select i1 %tobool.not.not, i64 %xor, i64 %add25.neg
  %checksum.1 = add i64 %xor.pn, %checksum.0152
  %inc28 = add nuw nsw i64 %j15.0153, 1
  %exitcond159.not = icmp eq i64 %inc28, %n
  br i1 %exitcond159.not, label %for.cond.cleanup18.loopexit, label %for.body19, !llvm.loop !29
}

; Function Attrs: mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite)
declare noalias noundef ptr @malloc(i64 noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @free(ptr allocptr nocapture noundef) local_unnamed_addr #3

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg) #4

attributes #0 = { nounwind uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { nofree norecurse nosync nounwind memory(readwrite, inaccessiblemem: none) uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #2 = { mustprogress nofree nounwind willreturn allockind("alloc,uninitialized") allocsize(0) memory(inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #3 = { mustprogress nounwind willreturn allockind("free") memory(argmem: readwrite, inaccessiblemem: readwrite) "alloc-family"="malloc" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #4 = { nocallback nofree nounwind willreturn memory(argmem: write) }
attributes #5 = { nounwind allocsize(0) }
attributes #6 = { nounwind }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{i32 8, !"PIC Level", i32 2}
!2 = !{i32 7, !"PIE Level", i32 2}
!3 = !{i32 7, !"uwtable", i32 2}
!4 = !{!"Ubuntu clang version 18.1.3 (1ubuntu1)"}
!5 = !{!6, !7, i64 0}
!6 = !{!"", !7, i64 0, !7, i64 8, !10, i64 16, !10, i64 24}
!7 = !{!"any pointer", !8, i64 0}
!8 = !{!"omnipotent char", !9, i64 0}
!9 = !{!"Simple C/C++ TBAA"}
!10 = !{!"long", !8, i64 0}
!11 = !{!6, !7, i64 8}
!12 = !{!6, !10, i64 16}
!13 = !{!6, !10, i64 24}
!14 = !{!10, !10, i64 0}
!15 = distinct !{!15, !16, !17}
!16 = !{!"llvm.loop.mustprogress"}
!17 = !{!"llvm.loop.unroll.disable"}
!18 = distinct !{!18, !16, !17}
!19 = distinct !{!19, !16, !17}
!20 = distinct !{!20, !16, !17}
!21 = distinct !{!21, !16, !17}
!22 = distinct !{!22, !16, !17}
!23 = distinct !{!23, !16, !17}
!24 = distinct !{!24, !16, !17}
!25 = distinct !{!25, !16, !17}
!26 = distinct !{!26, !16, !17}
!27 = distinct !{!27, !16, !17}
!28 = distinct !{!28, !16, !17}
!29 = distinct !{!29, !16, !17}
