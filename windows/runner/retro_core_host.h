#ifndef RUNNER_RETRO_CORE_HOST_H_
#define RUNNER_RETRO_CORE_HOST_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/texture_registrar.h>

#include <memory>

class RetroCoreSession;

class RetroCoreHost {
 public:
  RetroCoreHost(flutter::BinaryMessenger* messenger, flutter::TextureRegistrar* textures);
  ~RetroCoreHost();

 private:
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Release();

  flutter::TextureRegistrar* textures_;
  std::shared_ptr<RetroCoreSession> session_;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

#endif  // RUNNER_RETRO_CORE_HOST_H_
