; Function Signature: fdict(Int8, Int8)
;  @ /tmp/fdict_probe3.jl:2 within `fdict`
define i8 @julia_fdict_144(i8 signext %"k::Int8", i8 signext %"v::Int8") #0 {
top:
  %pgcstack = call ptr @julia.get_pgcstack()
;  @ /tmp/fdict_probe3.jl:3 within `fdict`
; ┌ @ dict.jl:78 within `Dict`
; │┌ @ boot.jl:588 within `GenericMemory`
    %"jl_global#146" = load ptr, ptr @"jl_global#146", align 8
; │└
; │ @ dict.jl:79 within `Dict`
; │┌ @ genericmemory.jl:205 within `fill!`
    %0 = call token (...) @llvm.julia.gc_preserve_begin(ptr %"jl_global#146")
; ││ @ genericmemory.jl:206 within `fill!`
; ││┌ @ pointer.jl:72 within `unsafe_convert`
     %.ptr_ptr = getelementptr inbounds i8, ptr %"jl_global#146", i32 8
; ││└
; ││ @ genericmemory.jl:208 within `fill!`
; ││┌ @ cmem.jl:42 within `memset`
     %.ptr_ptr.unbox = load ptr, ptr %.ptr_ptr, align 8
     call void @llvm.memset.p0.i64(ptr align 1 %.ptr_ptr.unbox, i8 0, i64 0, i1 false)
; ││└
; ││ @ genericmemory.jl:209 within `fill!`
    call void @llvm.julia.gc_preserve_end(token %0)
; │└
; │ @ dict.jl:80 within `Dict`
; │┌ @ boot.jl:588 within `GenericMemory`
    %"jl_global#147" = load ptr, ptr @"jl_global#147", align 8
    %"jl_global#1471" = load ptr, ptr @"jl_global#147", align 8
; │└
   %"+Main.Base.Dict#148" = load ptr, ptr @"+Main.Base.Dict#148", align 8
   %Dict = ptrtoint ptr %"+Main.Base.Dict#148" to i64
   %1 = inttoptr i64 %Dict to ptr
   %current_task = getelementptr inbounds i8, ptr %pgcstack, i32 -152
   %"new::Dict" = call noalias nonnull align 8 dereferenceable(64) ptr @julia.gc_alloc_obj(ptr %current_task, i64 64, ptr %1) #11
   %2 = getelementptr inbounds i8, ptr %"new::Dict", i32 0
   store ptr null, ptr %2, align 8
   %3 = getelementptr inbounds i8, ptr %"new::Dict", i32 8
   store ptr null, ptr %3, align 8
   %4 = getelementptr inbounds i8, ptr %"new::Dict", i32 16
   store ptr null, ptr %4, align 8
   store atomic ptr %"jl_global#146", ptr %"new::Dict" release, align 8
   %"new::Dict.keys_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 8
   store atomic ptr %"jl_global#147", ptr %"new::Dict.keys_ptr" release, align 8
   %"new::Dict.vals_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 16
   store atomic ptr %"jl_global#1471", ptr %"new::Dict.vals_ptr" release, align 8
   %"new::Dict.ndel_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 24
   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Dict.ndel_ptr", ptr align 8 @"_j_const#1", i64 8, i1 false)
   %"new::Dict.count_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 32
   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Dict.count_ptr", ptr align 8 @"_j_const#1", i64 8, i1 false)
   %"new::Dict.age_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 40
   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Dict.age_ptr", ptr align 8 @"_j_const#1", i64 8, i1 false)
   %"new::Dict.idxfloor_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 48
   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Dict.idxfloor_ptr", ptr align 8 @"_j_const#2", i64 8, i1 false)
   %"new::Dict.maxprobe_ptr" = getelementptr inbounds i8, ptr %"new::Dict", i32 56
   call void @llvm.memcpy.p0.p0.i64(ptr align 8 %"new::Dict.maxprobe_ptr", ptr align 8 @"_j_const#1", i64 8, i1 false)
; └
;  @ /tmp/fdict_probe3.jl:4 within `fdict`
  %5 = call nonnull ptr @"j_setindex!_149"(ptr %"new::Dict", i8 signext %"v::Int8", i8 signext %"k::Int8")
;  @ /tmp/fdict_probe3.jl:5 within `fdict`
; ┌ @ dict.jl:476 within `getindex`
; │┌ @ dict.jl:237 within `ht_keyindex`
; ││┌ @ dict.jl:705 within `isempty`
; │││┌ @ Base_compiler.jl:54 within `getproperty`
      %"new::Dict.count_ptr2" = getelementptr inbounds i8, ptr %"new::Dict", i32 32
      %"new::Dict.count" = load i64, ptr %"new::Dict.count_ptr2", align 8
; │││└
; │││┌ @ promotion.jl:637 within `==`
      %6 = icmp eq i64 %"new::Dict.count", 0
; ││└└
    %7 = xor i1 %6, true
    br i1 %7, label %L14, label %L13

L13:                                              ; preds = %top
    br label %L87

L14:                                              ; preds = %top
; ││ @ dict.jl:238 within `ht_keyindex`
; ││┌ @ Base_compiler.jl:54 within `getproperty`
     %"new::Dict.keys_ptr7" = getelementptr inbounds i8, ptr %"new::Dict", i32 8
     %"new::Dict.keys" = load atomic ptr, ptr %"new::Dict.keys_ptr7" unordered, align 8
; ││└
; ││ @ dict.jl:240 within `ht_keyindex`
; ││┌ @ Base_compiler.jl:54 within `getproperty`
     %"new::Dict.maxprobe_ptr8" = getelementptr inbounds i8, ptr %"new::Dict", i32 56
     %"new::Dict.maxprobe" = load i64, ptr %"new::Dict.maxprobe_ptr8", align 8
; ││└
; ││ @ dict.jl:241 within `ht_keyindex`
; ││┌ @ int.jl:83 within `<`
     %.unbox = load i64, ptr %"new::Dict.keys", align 8
     %8 = icmp slt i64 %"new::Dict.maxprobe", %.unbox
; ││└
    %9 = xor i1 %8, true
    br i1 %9, label %L84, label %L19

L19:                                              ; preds = %L14
; ││ @ dict.jl:242 within `ht_keyindex`
; ││┌ @ dict.jl:128 within `hashindex`
; │││┌ @ hashing.jl:28 within `hash` @ hashing.jl:89
; ││││┌ @ boot.jl:957 within `Int64`
; │││││┌ @ boot.jl:874 within `toInt64`
        %10 = sext i8 %"k::Int8" to i64
; ││││└└
; ││││ @ hashing.jl:28 within `hash` @ hashing.jl:89 @ hashing.jl:87
; ││││┌ @ hashing.jl:78 within `hash_uint64`
; │││││┌ @ hashing.jl:45 within `hash_64_64`
; ││││││┌ @ int.jl:327 within `~`
         %11 = xor i64 %10, -1
; ││││││└
; ││││││┌ @ int.jl:542 within `<<` @ int.jl:535
         %12 = shl i64 %10, 21
         %13 = select i1 false, i64 0, i64 %12
; ││││││└
; ││││││┌ @ int.jl:87 within `+`
         %14 = add i64 %11, %13
; ││││││└
; ││││││ @ hashing.jl:46 within `hash_64_64`
; ││││││┌ @ int.jl:540 within `>>` @ int.jl:534
         %15 = lshr i64 %14, 24
         %16 = select i1 false, i64 0, i64 %15
; ││││││└
; ││││││┌ @ int.jl:379 within `xor`
         %17 = xor i64 %14, %16
; ││││││└
; ││││││ @ hashing.jl:47 within `hash_64_64`
; ││││││┌ @ int.jl:542 within `<<` @ int.jl:535
         %18 = shl i64 %17, 3
         %19 = select i1 false, i64 0, i64 %18
         %20 = shl i64 %17, 8
         %21 = select i1 false, i64 0, i64 %20
; ││││││└
; ││││││┌ @ operators.jl:642 within `+` @ int.jl:87
         %22 = add i64 %17, %19
         %23 = add i64 %22, %21
; ││││││└
; ││││││ @ hashing.jl:48 within `hash_64_64`
; ││││││┌ @ int.jl:540 within `>>` @ int.jl:534
         %24 = lshr i64 %23, 14
         %25 = select i1 false, i64 0, i64 %24
; ││││││└
; ││││││┌ @ int.jl:379 within `xor`
         %26 = xor i64 %23, %25
; ││││││└
; ││││││ @ hashing.jl:49 within `hash_64_64`
; ││││││┌ @ int.jl:542 within `<<` @ int.jl:535
         %27 = shl i64 %26, 2
         %28 = select i1 false, i64 0, i64 %27
         %29 = shl i64 %26, 4
         %30 = select i1 false, i64 0, i64 %29
; ││││││└
; ││││││┌ @ operators.jl:642 within `+` @ int.jl:87
         %31 = add i64 %26, %28
         %32 = add i64 %31, %30
; ││││││└
; ││││││ @ hashing.jl:50 within `hash_64_64`
; ││││││┌ @ int.jl:540 within `>>` @ int.jl:534
         %33 = lshr i64 %32, 28
         %34 = select i1 false, i64 0, i64 %33
; ││││││└
; ││││││┌ @ int.jl:379 within `xor`
         %35 = xor i64 %32, %34
; ││││││└
; ││││││ @ hashing.jl:51 within `hash_64_64`
; ││││││┌ @ int.jl:542 within `<<` @ int.jl:535
         %36 = shl i64 %35, 31
         %37 = select i1 false, i64 0, i64 %36
; ││││││└
; ││││││┌ @ int.jl:87 within `+`
         %38 = add i64 %35, %37
; ││││└└└
; ││││┌ @ int.jl:86 within `-`
       %39 = sub i64 %38, 0
; │││└└
; │││ @ dict.jl:129 within `hashindex`
; │││┌ @ int.jl:86 within `-`
      %.unbox9 = load i64, ptr %"new::Dict.keys", align 8
      %40 = sub i64 %.unbox9, 1
; │││└
; │││┌ @ int.jl:353 within `&`
      %41 = and i64 %39, %40
; │││└
; │││┌ @ int.jl:87 within `+`
      %42 = add i64 %41, 1
; │││└
; │││ @ dict.jl:130 within `hashindex`
; │││┌ @ dict.jl:122 within `_shorthash7`
; ││││┌ @ int.jl:540 within `>>` @ int.jl:534
       %43 = lshr i64 %39, 57
       %44 = select i1 false, i64 0, i64 %43
; ││││└
; ││││┌ @ int.jl:550 within `rem`
       %45 = trunc i64 %44 to i8
; ││││└
; ││││┌ @ int.jl:378 within `|`
       %46 = or i8 %45, -128
; ││└└└
; ││ @ dict.jl:243 within `ht_keyindex`
; ││┌ @ Base_compiler.jl:54 within `getproperty`
     %"new::Dict.keys_ptr10" = getelementptr inbounds i8, ptr %"new::Dict", i32 8
     %memoryref_mem44 = load atomic ptr, ptr %"new::Dict.keys_ptr10" unordered, align 8
     br label %L49

L49:                                              ; preds = %L83, %L19
     %value_phi12 = phi i64 [ %42, %L19 ], [ %72, %L83 ]
     %value_phi13 = phi i64 [ 0, %L19 ], [ %73, %L83 ]
; ││└
; ││ @ dict.jl:246 within `ht_keyindex`
; ││┌ @ dict.jl:133 within `isslotempty`
; │││┌ @ Base_compiler.jl:54 within `getproperty`
      %memoryref_mem22 = load atomic ptr, ptr %"new::Dict" unordered, align 8
; │││└
; │││┌ @ essentials.jl:386 within `getindex`
      %memory_data_ptr14 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem22, i32 0, i32 1
      %memoryref_data16 = load ptr, ptr %memory_data_ptr14, align 8
      %47 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data16, 0
      %memory_ref15 = insertvalue { ptr, ptr } %47, ptr %memoryref_mem22, 1
      %memoryref_offset18 = sub i64 %value_phi12, 1
      %memoryref_byteoffset19 = mul i64 %memoryref_offset18, 1
      %memoryref_data_byteoffset20 = getelementptr i8, ptr %memoryref_data16, i64 %memoryref_byteoffset19
      %48 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data_byteoffset20, 0
      %memory_ref21 = insertvalue { ptr, ptr } %48, ptr %memoryref_mem22, 1
      %49 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem22, i32 0, i32 0
      %memory_len23 = load i64, ptr %49, align 8
      %50 = call ptr @julia.gc_loaded(ptr %memoryref_mem22, ptr %memoryref_data16)
      %memoryref_data24 = getelementptr inbounds i8, ptr %50, i64 %memoryref_byteoffset19
      %51 = load i8, ptr %memoryref_data24, align 1
; │││└
; │││┌ @ promotion.jl:637 within `==`
      %52 = icmp eq i8 %51, 0
; ││└└
    %53 = xor i1 %52, true
    br i1 %53, label %L59, label %L58

L58:                                              ; preds = %L49
    br label %L87

L59:                                              ; preds = %L49
; ││ @ dict.jl:247 within `ht_keyindex`
; ││┌ @ Base_compiler.jl:54 within `getproperty`
     %memoryref_mem33 = load atomic ptr, ptr %"new::Dict" unordered, align 8
; ││└
; ││┌ @ essentials.jl:386 within `getindex`
     %memory_data_ptr25 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem33, i32 0, i32 1
     %memoryref_data27 = load ptr, ptr %memory_data_ptr25, align 8
     %54 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data27, 0
     %memory_ref26 = insertvalue { ptr, ptr } %54, ptr %memoryref_mem33, 1
     %memoryref_offset29 = sub i64 %value_phi12, 1
     %memoryref_byteoffset30 = mul i64 %memoryref_offset29, 1
     %memoryref_data_byteoffset31 = getelementptr i8, ptr %memoryref_data27, i64 %memoryref_byteoffset30
     %55 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data_byteoffset31, 0
     %memory_ref32 = insertvalue { ptr, ptr } %55, ptr %memoryref_mem33, 1
     %56 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem33, i32 0, i32 0
     %memory_len34 = load i64, ptr %56, align 8
     %57 = call ptr @julia.gc_loaded(ptr %memoryref_mem33, ptr %memoryref_data27)
     %memoryref_data35 = getelementptr inbounds i8, ptr %57, i64 %memoryref_byteoffset30
     %58 = load i8, ptr %memoryref_data35, align 1
; ││└
; ││┌ @ promotion.jl:637 within `==`
     %59 = icmp eq i8 %46, %58
; ││└
    %60 = xor i1 %59, true
    br i1 %60, label %L76, label %L66

L66:                                              ; preds = %L59
; ││ @ dict.jl:248 within `ht_keyindex`
; ││┌ @ essentials.jl:386 within `getindex`
     %memory_data_ptr36 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem44, i32 0, i32 1
     %memoryref_data38 = load ptr, ptr %memory_data_ptr36, align 8
     %61 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data38, 0
     %memory_ref37 = insertvalue { ptr, ptr } %61, ptr %memoryref_mem44, 1
     %memoryref_offset40 = sub i64 %value_phi12, 1
     %memoryref_byteoffset41 = mul i64 %memoryref_offset40, 1
     %memoryref_data_byteoffset42 = getelementptr i8, ptr %memoryref_data38, i64 %memoryref_byteoffset41
     %62 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data_byteoffset42, 0
     %memory_ref43 = insertvalue { ptr, ptr } %62, ptr %memoryref_mem44, 1
     %63 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem44, i32 0, i32 0
     %memory_len45 = load i64, ptr %63, align 8
     %64 = call ptr @julia.gc_loaded(ptr %memoryref_mem44, ptr %memoryref_data38)
     %memoryref_data46 = getelementptr inbounds i8, ptr %64, i64 %memoryref_byteoffset41
     %65 = load i8, ptr %memoryref_data46, align 1
; ││└
; ││ @ dict.jl:249 within `ht_keyindex`
    %66 = icmp eq i8 %"k::Int8", %65
    %67 = xor i1 %66, true
    br i1 %67, label %L73, label %L72

L72:                                              ; preds = %L66
    br label %L75

L73:                                              ; preds = %L66
; ││┌ @ operators.jl:178 within `isequal`
; │││┌ @ promotion.jl:637 within `==`
      %68 = icmp eq i8 %"k::Int8", %65
; ││└└
    %69 = xor i1 %68, true
    br i1 %69, label %L76, label %L75

L75:                                              ; preds = %L73, %L72
; ││ @ dict.jl:250 within `ht_keyindex`
    br label %L87

L76:                                              ; preds = %L73, %L59
; ││ @ dict.jl:254 within `ht_keyindex`
; ││┌ @ int.jl:86 within `-`
     %.unbox47 = load i64, ptr %"new::Dict.keys", align 8
     %70 = sub i64 %.unbox47, 1
; ││└
; ││┌ @ int.jl:353 within `&`
     %71 = and i64 %value_phi12, %70
; ││└
; ││┌ @ int.jl:87 within `+`
     %72 = add i64 %71, 1
; ││└
; ││ @ dict.jl:255 within `ht_keyindex`
; ││┌ @ int.jl:87 within `+`
     %73 = add i64 %value_phi13, 1
; ││└
; ││┌ @ operators.jl:425 within `>`
; │││┌ @ int.jl:83 within `<`
      %74 = icmp slt i64 %"new::Dict.maxprobe", %73
; ││└└
    %75 = xor i1 %74, true
    br i1 %75, label %L83, label %L82

L82:                                              ; preds = %L76
    br label %L87

L83:                                              ; preds = %L76
; ││ @ dict.jl:256 within `ht_keyindex`
    br label %L49

L84:                                              ; preds = %L14
; ││ @ dict.jl:241 within `ht_keyindex`
; ││┌ @ boot.jl:451 within `AssertionError`
     %"jl_global#152" = load ptr, ptr @"jl_global#152", align 8
     %76 = call [1 x ptr] @j_AssertionError_151(ptr %"jl_global#152")
; ││└
    %"+Core.AssertionError#153" = load ptr, ptr @"+Core.AssertionError#153", align 8
    %AssertionError = ptrtoint ptr %"+Core.AssertionError#153" to i64
    %77 = inttoptr i64 %AssertionError to ptr
    %current_task48 = getelementptr inbounds i8, ptr %pgcstack, i32 -152
    %"box::AssertionError" = call noalias nonnull align 8 dereferenceable(8) ptr @julia.gc_alloc_obj(ptr %current_task48, i64 8, ptr %77) #11
    store [1 x ptr] %76, ptr %"box::AssertionError", align 8
    call void @ijl_throw(ptr %"box::AssertionError")
    unreachable

L87:                                              ; preds = %L82, %L75, %L58, %L13
    %value_phi = phi i64 [ -1, %L13 ], [ -1, %L58 ], [ %value_phi12, %L75 ], [ -1, %L82 ]
; │└
; │ @ dict.jl:477 within `getindex`
; │┌ @ int.jl:83 within `<`
    %78 = icmp slt i64 %value_phi, 0
; │└
   %79 = xor i1 %78, true
   br i1 %79, label %L93, label %L90

L90:                                              ; preds = %L87
; │┌ @ abstractdict.jl:12 within `KeyError`
    %80 = zext i8 %"k::Int8" to i32
    %81 = getelementptr inbounds [256 x ptr], ptr @jl_boxed_int8_cache, i32 0, i32 %80
    %82 = load ptr, ptr %81, align 8
; │└
   %"+Main.Base.KeyError#150" = load ptr, ptr @"+Main.Base.KeyError#150", align 8
   %KeyError = ptrtoint ptr %"+Main.Base.KeyError#150" to i64
   %83 = inttoptr i64 %KeyError to ptr
   %current_task3 = getelementptr inbounds i8, ptr %pgcstack, i32 -152
   %"box::KeyError" = call noalias nonnull align 8 dereferenceable(8) ptr @julia.gc_alloc_obj(ptr %current_task3, i64 8, ptr %83) #11
   %84 = getelementptr inbounds i8, ptr %"box::KeyError", i32 0
   store atomic ptr %82, ptr %84 unordered, align 8
   call void @ijl_throw(ptr %"box::KeyError")
   unreachable

L93:                                              ; preds = %L87
; │┌ @ Base_compiler.jl:54 within `getproperty`
    %"new::Dict.vals_ptr4" = getelementptr inbounds i8, ptr %"new::Dict", i32 16
    %memoryref_mem = load atomic ptr, ptr %"new::Dict.vals_ptr4" unordered, align 8
; │└
; │ @ dict.jl:477 within `getindex` @ essentials.jl:386
   %memory_data_ptr = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem, i32 0, i32 1
   %memoryref_data = load ptr, ptr %memory_data_ptr, align 8
   %85 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data, 0
   %memory_ref = insertvalue { ptr, ptr } %85, ptr %memoryref_mem, 1
   %memoryref_offset = sub i64 %value_phi, 1
   %memoryref_byteoffset = mul i64 %memoryref_offset, 1
   %memoryref_data_byteoffset = getelementptr i8, ptr %memoryref_data, i64 %memoryref_byteoffset
   %86 = insertvalue { ptr, ptr } zeroinitializer, ptr %memoryref_data_byteoffset, 0
   %memory_ref5 = insertvalue { ptr, ptr } %86, ptr %memoryref_mem, 1
   %87 = getelementptr inbounds { i64, ptr }, ptr %memoryref_mem, i32 0, i32 0
   %memory_len = load i64, ptr %87, align 8
   %88 = call ptr @julia.gc_loaded(ptr %memoryref_mem, ptr %memoryref_data)
   %memoryref_data6 = getelementptr inbounds i8, ptr %88, i64 %memoryref_byteoffset
   %89 = load i8, ptr %memoryref_data6, align 1
; │ @ dict.jl:477 within `getindex`
   br label %L99

L99:                                              ; preds = %L93
; └
  ret i8 %89

after_throw:                                      ; No predecessors!
; ┌ @ dict.jl:477 within `getindex`
   call void @llvm.trap()
   unreachable

after_noret:                                      ; No predecessors!
   call void @llvm.trap()
   unreachable

after_throw49:                                    ; No predecessors!
; │ @ dict.jl:476 within `getindex`
; │┌ @ dict.jl:241 within `ht_keyindex`
    call void @llvm.trap()
    unreachable

after_noret50:                                    ; No predecessors!
    call void @llvm.trap()
    unreachable
; └└
}
