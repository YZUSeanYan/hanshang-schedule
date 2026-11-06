"""协议一致性守卫：真实网关必须能被按 EventParseGateway 协议调用。

背景（2026-09-22）：MimoEventGateway.transcribe_partial 的方法体在使用 hint，
签名却没声明它——调用方传 hint= 抛 TypeError、不传抛 NameError，两条路都是
HTTP 500，线上实时语音上屏静默失效。既有测试因为用的是签名正确的桩网关而
全部通过，所以这里专门针对「实现 vs 协议」做签名比对，而不是测端点行为。
"""
import inspect

from app.services.llm_event_parse import (
    EventParseGateway,
    MimoEventGateway,
    UnavailableEventGateway,
)

IMPLEMENTATIONS = [MimoEventGateway, UnavailableEventGateway]


def _protocol_methods() -> dict[str, inspect.Signature]:
    methods: dict[str, inspect.Signature] = {}
    for name, member in vars(EventParseGateway).items():
        if name.startswith("_") or not callable(member):
            continue
        methods[name] = inspect.signature(member)
    return methods


def test_protocol_declares_expected_methods():
    """协议本身别被改空——否则下面的比对会变成空转。"""
    assert set(_protocol_methods()) == {
        "parse",
        "transcribe_partial",
        "parse_holiday",
        "chat",
        "goal_plan",
    }


def test_implementations_accept_every_protocol_parameter():
    """实现必须接受协议声明的每个参数（含带默认值的关键字参数）。"""
    protocol = _protocol_methods()
    for impl_cls in IMPLEMENTATIONS:
        for method_name, proto_sig in protocol.items():
            impl = getattr(impl_cls, method_name, None)
            assert impl is not None, f"{impl_cls.__name__} 缺少协议方法 {method_name}"
            impl_sig = inspect.signature(impl)
            for param_name, param in proto_sig.parameters.items():
                if param_name == "self":
                    continue
                assert param_name in impl_sig.parameters, (
                    f"{impl_cls.__name__}.{method_name} 未声明协议参数 "
                    f"{param_name}——调用方会传它，运行时必炸"
                )
                impl_param = impl_sig.parameters[param_name]
                assert impl_param.kind in (
                    inspect.Parameter.POSITIONAL_OR_KEYWORD,
                    inspect.Parameter.KEYWORD_ONLY,
                ), f"{impl_cls.__name__}.{method_name} 参数 {param_name} 无法按关键字调用"


def test_transcribe_partial_accepts_hint_keyword():
    """回归：hint 漏声明曾让 /api/schedule-ai/transcribe 每次 500。"""
    for impl_cls in IMPLEMENTATIONS:
        sig = inspect.signature(impl_cls.transcribe_partial)
        assert "hint" in sig.parameters
        assert sig.parameters["hint"].default == ""


def test_transcribe_partial_is_callable_with_hint_end_to_end():
    """回归：直接跑真实方法体。

    hint 漏声明时这里会以两种方式之一炸掉——传 hint= 是 TypeError，
    不传则是方法体读未定义名抛 NameError。两者都对应线上 /transcribe 的 500。
    """
    import asyncio
    import base64

    captured: dict[str, object] = {}

    async def fake_chat(messages, *, json_mode, model=None):
        captured["messages"] = messages
        captured["json_mode"] = json_mode
        captured["model"] = model
        return "  明天下午三点开会  "

    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    gateway._chat = fake_chat  # type: ignore[method-assign]

    # ≥3200 字节解码后长度，越过「太短静默返回空」的门槛
    pcm = b"\x00\x01" * 2000
    audio_b64 = base64.b64encode(pcm).decode()

    text = asyncio.run(
        gateway.transcribe_partial(audio_b64, hint="本次录音涉及的地名：文津楼")
    )

    assert text == "明天下午三点开会", "返回值应去掉首尾空白"
    assert captured["model"] == "mimo-v2.5-asr", "分段转写必须仍走 ASR 模型"
    assert captured["json_mode"] is False, "转写结果不能加 JSON mode"

    content = captured["messages"][0]["content"]  # type: ignore[index]
    assert content[0]["type"] == "input_audio"
    assert all(
        part.get("type") != "text" for part in content
    ), (
        "ASR 请求不得携带 text 块：MiMo 自 2026-09-22 起会以 400 拒绝并让整条语音"
        "链路 502；hint 只是保留形参，不再发送"
    )


def test_transcribe_partial_works_without_hint():
    """不传 hint 也要能跑（端点在不传词表时走的就是这条路）。"""
    import asyncio
    import base64

    async def fake_chat(messages, *, json_mode, model=None):
        return "开会"

    gateway = MimoEventGateway(
        base_url="https://example.invalid/v1",
        api_key="test-key",
        model="mimo-v2.6-flash",
        asr_model="mimo-v2.5-asr",
        timeout_seconds=5,
    )
    gateway._chat = fake_chat  # type: ignore[method-assign]

    audio_b64 = base64.b64encode(b"\x00\x01" * 2000).decode()
    assert asyncio.run(gateway.transcribe_partial(audio_b64)) == "开会"

