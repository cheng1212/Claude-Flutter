// 动效 token:全库动画时长/曲线的唯一出处(T8)。
// 原则:交互反馈 150-250ms、转场 ~300ms、有目的才动。
// 引入新动画从这里取值;不引入 flutter_animate/Lottie(守「小依赖」原则)。
import 'package:flutter/material.dart';

/// 快速交互反馈(按压/复制成功等)
const kDurFast = Duration(milliseconds: 150);

/// 常规反馈(入 场淡入/错误条重现)
const kDurNormal = Duration(milliseconds: 220);

/// 页面级转场(回到底部动画等)
const kDurPage = Duration(milliseconds: 300);

const kCurveOut = Curves.easeOutCubic;
const kCurveInOut = Curves.easeInOutCubic;
