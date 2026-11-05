#pragma once

#include <react/renderer/core/LayoutPrimitives.h>
#include <react/renderer/graphics/Point.h>
#include <react/renderer/graphics/Size.h>
#include <yoga/style/Style.h>

namespace rnscreens {

namespace react = facebook::react;
namespace yoga = facebook::yoga;

/**
 * Base for shadow nodes whose component descriptor sets their Yoga size from
 * native state in `adopt()`: `SizeFromStateShadowNode<ConcreteViewShadowNode<...>>`.
 */
template <typename BaseShadowNodeT>
class SizeFromStateShadowNode : public BaseShadowNodeT {
 public:
  using BaseShadowNodeT::BaseShadowNodeT;

  /**
   * Like `setSize`, but leaves the Yoga node clean when its style already has
   * this size. `adopt()` runs on every clone, and an unconditional `setSize`
   * dirties the root, so every commit re-ran layout over the whole tree.
   */
  void setSizeIfChanged(react::Size size) const {
    const yoga::Style &style = this->yogaNode_.style();
    const bool hasSize = style.dimension(yoga::Dimension::Width) ==
            yoga::StyleSizeLength::points(size.width) &&
        style.dimension(yoga::Dimension::Height) ==
            yoga::StyleSizeLength::points(size.height);
    if (!hasSize) {
      this->setSize(size);
    }
  }
};

/**
 * Dirties the node when the frame origin its `layout()` takes from state no
 * longer matches its layout metrics. `ShadowNodeT` needs
 * `Point correctFrameOrigin(Point origin) const`.
 */
template <typename ShadowNodeT>
void dirtyLayoutIfFrameOriginStale(ShadowNodeT &shadowNode) {
  const auto layoutMetrics = shadowNode.getLayoutMetrics();
  if (layoutMetrics.displayType == react::DisplayType::None) {
    return;
  }
  const auto origin = layoutMetrics.frame.origin;
  if (shadowNode.correctFrameOrigin(origin) != origin) {
    shadowNode.dirtyLayout();
  }
}

} // namespace rnscreens
