#include "RNSScreenStackHeaderSubviewShadowNode.h"

namespace facebook::react {

extern const char RNSScreenStackHeaderSubviewComponentName[] =
    "RNSScreenStackHeaderSubview";

void RNSScreenStackHeaderSubviewShadowNode::layout(
    LayoutContext layoutContext) {
  YogaLayoutableShadowNode::layout(layoutContext);
  applyFrameCorrections();
}

void RNSScreenStackHeaderSubviewShadowNode::applyFrameCorrections() {
  ensureUnsealed();

  layoutMetrics_.frame.origin = correctFrameOrigin(layoutMetrics_.frame.origin);
}

Point RNSScreenStackHeaderSubviewShadowNode::correctFrameOrigin(
    Point /*origin*/) const {
  return getStateData().contentOffset;
}

} // namespace facebook::react
