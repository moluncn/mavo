import Foundation

enum SelfTestFailure: Error {
    case failed(String)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw SelfTestFailure.failed(message) }
}

func expectDecodeFailure(_ pdu: String, _ message: String) throws {
    do {
        _ = try SMSPDUDecoder.decode(pdu)
        throw SelfTestFailure.failed(message)
    } catch is SMSPDUDecoderError {
        return
    } catch {
        throw error
    }
}

do {
    let tombstoneRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MaVo-message-tombstone-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tombstoneRoot) }
    let tombstoneDate = Date(timeIntervalSince1970: 1_700_000_000)
    let tombstoneID = "stable-pdu-sha256"
    let tombstoneURL = tombstoneRoot.appendingPathComponent("deleted-message-ids.json")
    var tombstoneRegistry = DeletedMessageRegistry(fileURL: tombstoneURL)
    try expect(!tombstoneRegistry.contains(tombstoneID), "new deletion registry was not empty")
    tombstoneRegistry.insert(tombstoneID, at: tombstoneDate)
    try expect(tombstoneRegistry.contains(tombstoneID), "deletion registry lost current entry")
    let reloadedTombstoneRegistry = DeletedMessageRegistry(fileURL: tombstoneURL)
    try expect(
        reloadedTombstoneRegistry.contains(tombstoneID),
        "deletion registry lost entry after persistent reload"
    )

    let launchAgentPropertyList = LaunchAtLoginController.propertyList(
        appBundlePath: "/Users/test/Applications/MaVo.app"
    )
    try expect(
        launchAgentPropertyList["Label"] as? String == "app.mavo.mac.launch-at-login",
        "LaunchAgent label"
    )
    try expect(
        launchAgentPropertyList["ProgramArguments"] as? [String] == [
            "/usr/bin/open", "-g", "/Users/test/Applications/MaVo.app",
        ],
        "LaunchAgent app path"
    )
    try expect(
        launchAgentPropertyList["RunAtLoad"] as? Bool == true &&
            launchAgentPropertyList["KeepAlive"] == nil,
        "LaunchAgent must run once per login without relaunching after a manual quit"
    )
    _ = try PropertyListSerialization.data(
        fromPropertyList: launchAgentPropertyList,
        format: .xml,
        options: 0
    )

    try expect(
        SMSVerificationCodeExtractor.extract(from: "【MaVo】您的验证码为 482913，5 分钟内有效。") == "482913",
        "Chinese verification code extraction"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "7315 是您的登录验证码，请勿告诉他人。") == "7315",
        "verification code before keyword"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "Your verification code is A7K9Q2. Do not share it.") == "A7K9Q2",
        "alphanumeric verification code extraction"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "订单号 482913 已发货，预计明天送达。") == nil,
        "ordinary order number classified as verification code"
    )
    try expect(
        SMSVerificationCodeExtractor.extract(from: "订单 123456 的验证码是 654321。") == "654321",
        "nearby order number took precedence over verification code"
    )
    let verificationReadDate = Date(timeIntervalSince1970: 1_000)
    let readVerificationMessage = SMSMessage(
        id: "verification-read",
        modemIndices: [],
        sender: "MaVo",
        body: "您的验证码为 482913。",
        timestamp: verificationReadDate,
        rawPDUs: [],
        isRead: true,
        readAt: verificationReadDate,
        firstSeenAt: verificationReadDate
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: readVerificationMessage,
            enabled: true
        ) == Date(timeIntervalSince1970: 2_800),
        "verification auto-delete deadline"
    )
    var unreadVerificationMessage = readVerificationMessage
    unreadVerificationMessage.isRead = false
    unreadVerificationMessage.readAt = nil
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: unreadVerificationMessage,
            enabled: true
        ) == nil,
        "unread verification message scheduled for deletion"
    )
    let ordinaryReadMessage = SMSMessage(
        id: "ordinary-read",
        modemIndices: [],
        sender: "Shop",
        body: "订单号 482913 已发货。",
        timestamp: verificationReadDate,
        rawPDUs: [],
        isRead: true,
        readAt: verificationReadDate,
        firstSeenAt: verificationReadDate
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: ordinaryReadMessage,
            enabled: true
        ) == nil,
        "ordinary read message scheduled for verification deletion"
    )
    try expect(
        VerificationMessageAutoDeletePolicy.deletionDate(
            for: readVerificationMessage,
            enabled: false
        ) == nil,
        "disabled verification auto-delete policy scheduled a message"
    )
    var refreshedVerificationMessage = readVerificationMessage
    refreshedVerificationMessage.isRead = false
    refreshedVerificationMessage.readAt = nil
    let preservedReadState = SMSMessageMerger.merge(
        existing: [readVerificationMessage],
        incoming: [refreshedVerificationMessage]
    ).messages.first
    try expect(
        preservedReadState?.isRead == true && preservedReadState?.readAt == verificationReadDate,
        "message refresh erased verification read time"
    )

    let adbPayload = Data("host::MaVo\0".utf8)
    let adbHeader = ADBWire.encodeHeader(
        command: ADBWire.cnxn,
        argument0: 0x01000001,
        argument1: 4_096,
        payload: adbPayload
    )
    let adbMessage = try ADBWire.decodeHeader(adbHeader, payload: adbPayload)
    try expect(adbHeader.count == 24, "ADB header size")
    try expect(adbMessage.command == ADBWire.cnxn, "ADB CNXN command encoding")
    try expect(adbMessage.payload == adbPayload, "ADB payload round trip")
    let syncData = ADBWire.syncPacket(identifier: "DATA", payload: Data([1, 2, 3]))
    try expect(
        syncData == Data([0x44, 0x41, 0x54, 0x41, 3, 0, 0, 0, 1, 2, 3]),
        "ADB sync DATA frame"
    )
    let checkedCommand = ADBWire.checkedShellCommand("id", token: "ABC123")
    try expect(
        checkedCommand.contains("__MAVO_STATUS_ABC123_"),
        "ADB checked shell marker"
    )
    let checkedResult = try ADBWire.parseCheckedShellOutput(
        "uid=0(root)\r\n__MAVO_STATUS_ABC123_0__\r\n",
        token: "ABC123"
    )
    try expect(checkedResult.output == "uid=0(root)", "ADB checked shell output")
    try expect(checkedResult.status == 0, "ADB checked shell status")

    try expect(
        CallATParser.normalizedDialNumber("+86 (138) 0013-8000") == "+8613800138000",
        "formatted dial number normalization"
    )
    try expect(CallATParser.normalizedDialNumber("13800138000;ATH") == nil, "AT dial injection accepted")
    try expect(CallATParser.normalizedDialNumber("13800138000\r") == nil, "dial CR injection accepted")
    try expect(CallATParser.normalizedDialNumber("١٣٨٠٠١٣٨٠٠٠") == nil, "non-ASCII dial digits accepted")
    for tone in ["0", "9", "*", "#"] {
        try expect(CallATParser.normalizedDTMFTone(tone) == tone, "valid DTMF tone rejected: \(tone)")
        try expect(
            CallATParser.dtmfCommand(for: tone) == "AT+VTS=\"\(tone)\"",
            "DTMF command did not use the documented quoted syntax: \(tone)"
        )
    }
    for invalidTone in ["", "12", "A", "１", "1;ATH", "\r", "\n"] {
        try expect(
            CallATParser.normalizedDTMFTone(invalidTone) == nil &&
                CallATParser.dtmfCommand(for: invalidTone) == nil,
            "invalid DTMF tone accepted: \(invalidTone.debugDescription)"
        )
    }

    let trimmedATCommand = try ATConsoleCommandValidator.validate("  at+csq  ")
    try expect(trimmedATCommand == "at+csq", "AT console trimming")
    for invalidCommand in ["", "CSQ", "AT+CSQ\r\nATD10000;", "AT+中文"] {
        do {
            _ = try ATConsoleCommandValidator.validate(invalidCommand)
            throw SelfTestFailure.failed("AT console accepted invalid input: \(invalidCommand.debugDescription)")
        } catch is ATConsoleCommandError {
            // Expected.
        }
    }
    for managedCommand in ["ATD10000;", "ATA", "ATH", "AT+VTS=1"] {
        do {
            _ = try ATConsoleCommandValidator.validate(managedCommand)
            throw SelfTestFailure.failed("AT console accepted app-managed call command: \(managedCommand)")
        } catch ATConsoleCommandError.managedCallCommand {
            // Expected.
        }
    }
    do {
        _ = try ATConsoleCommandValidator.validate("AT+CMGS=23")
        throw SelfTestFailure.failed("AT console accepted prompt-based CMGS")
    } catch ATConsoleCommandError.interactivePrompt {
        // Expected.
    }
    let cmgsCapabilityQuery = try ATConsoleCommandValidator.validate("AT+CMGS=?")
    try expect(
        cmgsCapabilityQuery == "AT+CMGS=?",
        "AT console rejected non-interactive capability query"
    )

    try expect(
        ATResponseParser.parseSubscriberNumber("\r\n+CNUM: \"\",\"13800138000\",129\r\nOK\r\n") ==
            "13800138000",
        "CNUM national subscriber number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber("+CNUM: \"Voice\",\"8613800138000\",145") ==
            "+8613800138000",
        "CNUM international subscriber number"
    )
    try expect(
        ATResponseParser.parseSubscriberNumber("+CNUM: \"\",\"\",129\r\nOK") == nil,
        "empty CNUM response produced a number"
    )
    try expect(
        ATResponseParser.parseICCID("\r\n+QCCID: 89860312345678901234\r\nOK\r\n") ==
            "89860312345678901234",
        "Quectel ICCID parsing"
    )
    try expect(
        ATResponseParser.parseICCID("\r\n8986112233445566778\r\nOK\r\n") ==
            "8986112233445566778",
        "standard bare ICCID parsing"
    )

    var voiceConditioner = VoiceCaptureConditioner()
    let dcInput = [Float](repeating: 0.5, count: 48_000)
    let dcOutput = voiceConditioner.process(dcInput, sampleRate: 48_000)
    try expect(
        abs(dcOutput.suffix(1_000).reduce(0, +) / 1_000) < 0.001,
        "voice conditioner did not remove microphone DC"
    )
    voiceConditioner.reset()
    let highFrequency = (0 ..< 4_800).map { index in
        Float(sin(2 * Double.pi * 10_000 * Double(index) / 48_000))
    }
    let filteredHighFrequency = voiceConditioner.process(highFrequency, sampleRate: 48_000)
    let filteredPeak = filteredHighFrequency.suffix(2_400).map(abs).max() ?? 1
    try expect(filteredPeak < 0.2, "voice conditioner did not attenuate alias-prone audio")

    let singleSubmit = try SMSPDUEncoder.encode(
        destination: "+1234567890",
        body: "你好",
        concatenationReference: 0xAA
    )
    try expect(singleSubmit.count == 1, "short UCS-2 SMS was segmented")
    try expect(
        singleSubmit[0].pdu == "0001000A9121436587090008044F60597D",
        "short UCS-2 SMS-SUBMIT PDU"
    )
    try expect(singleSubmit[0].tpduLength == 16, "CMGS TPDU length included SMSC octet")
    try expect(SMSPDUEncoder.isValidDestination("+86 138-0013-8000"), "reply number validation")
    try expect(!SMSPDUEncoder.isValidDestination("China Telecom"), "alphanumeric sender reply validation")
    let oddDestinationSubmit = try SMSPDUEncoder.encode(
        destination: "10086",
        body: "A",
        concatenationReference: 0xAA
    )
    try expect(
        oddDestinationSubmit[0].pdu.contains("05810180F60008020041"),
        "odd-length destination semi-octet encoding"
    )
    let multipartSubmit = try SMSPDUEncoder.encode(
        destination: "10086",
        body: String(repeating: "你", count: 71),
        concatenationReference: 0xAA
    )
    try expect(multipartSubmit.count == 2, "long UCS-2 SMS segment count")
    try expect(
        multipartSubmit[0].pdu.contains("050003AA0201") &&
            multipartSubmit[1].pdu.contains("050003AA0202"),
        "multipart SMS UDH sequence"
    )
    try expect(
        multipartSubmit[0].sequence == 1 && multipartSubmit[1].sequence == 2,
        "multipart SMS sequence metadata"
    )
    let surrogateBoundary = try SMSPDUEncoder.encode(
        destination: "10086",
        body: String(repeating: "a", count: 66) + "😀" + String(repeating: "b", count: 4),
        concatenationReference: 0x55
    )
    try expect(surrogateBoundary.count == 2, "surrogate boundary SMS segment count")
    try expect(
        surrogateBoundary[1].pdu.contains("D83DDE00"),
        "multipart SMS split a UTF-16 surrogate pair"
    )
    do {
        _ = try SMSPDUEncoder.encode(
            destination: "10086;AT+CFUN=1",
            body: "blocked",
            concatenationReference: 0
        )
        throw SelfTestFailure.failed("SMS destination accepted AT injection")
    } catch is SMSPDUEncoderError {
        // Expected.
    }
    var readyCall = CallSnapshot(phase: .idle, voiceOverUSBSupported: true)
    try expect(readyCall.canDial, "clean idle call state cannot dial")
    readyCall.lastError = "last recoverable error"
    try expect(readyCall.canDial, "ordinary display error permanently blocked dialing")
    readyCall.mediaCleanupPending = true
    try expect(!readyCall.canDial, "confirmed media cleanup pending did not block a new call")
    var activeCall = CallSnapshot(phase: .active, voiceOverUSBSupported: true, audioActive: false)
    try expect(activeCall.canSendDTMF, "active call could not send network DTMF while audio was recovering")
    activeCall.mediaCleanupPending = true
    try expect(activeCall.canSendDTMF, "owned active media route incorrectly blocked DTMF")
    activeCall = CallSnapshot(phase: .alerting, voiceOverUSBSupported: true, audioActive: true)
    try expect(!activeCall.canSendDTMF, "DTMF was enabled before active CLCC")
    let outgoingCLCC = CallATParser.parseCLCC("+CLCC: 1,0,3,0,0,\"13800138000\",129")
    try expect(outgoingCLCC?.direction == .outgoing, "outgoing CLCC direction")
    try expect(outgoingCLCC?.status == .alerting, "outgoing CLCC status")
    try expect(outgoingCLCC?.number == "13800138000", "outgoing CLCC number")
    let incomingCLCC = CallATParser.parseCLCC("+CLCC: 2,1,4,0,0,\"10000\",129")
    try expect(incomingCLCC?.direction == .incoming, "incoming CLCC direction")
    try expect(incomingCLCC?.status == .incoming, "incoming CLCC status")
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: AppNotificationIdentifier.answerCallAction,
            categoryIdentifier: AppNotificationIdentifier.incomingCallCategory,
            messageID: nil,
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .answerCall,
        "incoming-call notification answer action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: AppNotificationIdentifier.rejectCallAction,
            categoryIdentifier: AppNotificationIdentifier.incomingCallCategory,
            messageID: nil,
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .rejectCall,
        "incoming-call notification reject action"
    )
    try expect(
        AppNotificationRouter.route(
            actionIdentifier: "default",
            categoryIdentifier: AppNotificationIdentifier.messageCategory,
            messageID: "message-1",
            defaultActionIdentifier: "default",
            dismissActionIdentifier: "dismiss"
        ) == .openMessage("message-1"),
        "message notification default action"
    )
    try expect(
        CallATParser.testResponseSupportsRawPCM("+QPCMV: (0,1),(0-2)\r\nOK\r\n"),
        "QPCMV option 0 capability"
    )
    try expect(
        CallATParser.testResponseSupportsRawPCM("+QPCMV: (0,1),(0,2)\r\nOK\r\n"),
        "QPCMV enumerated option 0 capability"
    )
    try expect(
        CallATParser.preferredMediaBackend(
            firmwareIdentity: "QDC507GLEFM21_01.001.01.007",
            supportsRawPCM: true,
            hasUSBLocation: true
        ) == .qdcModuleBridge,
        "QDC507 must take priority over its misleading QPCMV capability response"
    )
    try expect(
        CallATParser.preferredMediaBackend(
            firmwareIdentity: "EC25EFAR06A06M4G",
            supportsRawPCM: true,
            hasUSBLocation: true
        ) == .qpcmv,
        "standard EC25 raw PCM backend selection"
    )
    var callFramer = CallURCStreamFramer()
    try expect(callFramer.consume("\r\n+CLI").isEmpty, "partial CLIP emitted")
    try expect(
        callFramer.consume("P: \"10000\",129\r\n") == [.callerID("10000")],
        "split CLIP framing"
    )
    try expect(
        callFramer.consume("+QPCMV: 0,0\r\n+QPCMV: 1\r\n") == [
            .pcmFlowReady(false),
            .pcmFlowReady(true),
        ],
        "QPCMV flow-control formats"
    )
    try expect(
        callFramer.consume("RING\r\nNO CARRIER\r\n") == [.ring, .ended(.remoteHangup)],
        "call terminal URCs"
    )

    let ucs2PDU = "00040A912143658709000862702110203023044F60597D"
    let ucs2 = try SMSPDUDecoder.decode(ucs2PDU)
    try expect(ucs2.sender == "+1234567890", "UCS2 sender")
    try expect(ucs2.body == "你好", "UCS2 body")
    try expect(ucs2.concatenation == nil, "unexpected UDH")

    let gsm7PDU = "00040A91214365870900006270211020302305E8329BFD06"
    let gsm7 = try SMSPDUDecoder.decode(gsm7PDU)
    try expect(gsm7.sender == "+1234567890", "GSM-7 sender")
    try expect(gsm7.body == "hello", "GSM-7 body")

    let alphaSenderPDU = "000407D0C2A0730900006270211020302305E8329BFD06"
    let alphaSender = try SMSPDUDecoder.decode(alphaSenderPDU)
    try expect(alphaSender.sender == "BANK", "alphanumeric sender")
    try expect(alphaSender.body == "hello", "alphanumeric sender body alignment")

    let udhPDU = "00400A9121436587090000627021102030230C050003CC0201D06536FB0D"
    let udh = try SMSPDUDecoder.decode(udhPDU)
    try expect(udh.body == "hello", "GSM-7 UDH fill bits")
    try expect(udh.concatenation?.reference == 204, "8-bit concat reference")
    try expect(udh.concatenation?.referenceBits == 8, "8-bit concat width")
    try expect(udh.concatenation?.total == 2 && udh.concatenation?.sequence == 1, "concat sequence")

    try expectDecodeFailure(
        "00040A91214365870900006270211020302305E832",
        "truncated GSM-7 user data was accepted"
    )
    try expectDecodeFailure(
        "00040A912143658709000862702110203023044F60",
        "truncated UCS2 user data was accepted"
    )
    let paddedUCS2 = try SMSPDUDecoder.decode(
        "00040A912143658709000862702110203023044F60597D574F"
    )
    try expect(paddedUCS2.body == "你好", "TP-UDL did not trim extra UCS2 bytes")
    let invalidDate = try SMSPDUDecoder.decode(
        "00040A912143658709000862201310203023044F60597D"
    )
    try expect(invalidDate.timestamp == nil, "invalid SCTS date was normalized instead of rejected")
    let invalidTimezone = try SMSPDUDecoder.decode(
        "00040A9121436587090008627021102030FF044F60597D"
    )
    try expect(invalidTimezone.timestamp == nil, "invalid SCTS timezone was accepted")

    let response = "+CMGL: 7,0,,22\r\n\(ucs2PDU)FFFF\r\nOK\r\n"
    let entries = ATResponseParser.parseCMGL(response)
    try expect(entries.count == 1, "CMGL entry count")
    try expect(entries[0].index == 7, "CMGL index")
    try expect(entries[0].status == 0, "CMGL status")
    try expect(entries[0].rawPDU == ucs2PDU, "CMGL length trimming")

    let shortCMGL = ATResponseParser.parseCMGL(
        "+CMGL: 7,0,,30\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(shortCMGL.isEmpty, "CMGL accepted data shorter than declared TPDU length")
    let textStatus = ATResponseParser.parseCMGL(
        "+CMGL: 8,\"REC UNREAD\",,22\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(textStatus.first?.status == 0, "quoted CMGL status")
    let missingLength = ATResponseParser.parseCMGL(
        "+CMGL: 9,0\r\n\(ucs2PDU)\r\nOK\r\n"
    )
    try expect(missingLength.isEmpty, "CMGL header without TPDU length was accepted")
    try expect(
        ATResponseParser.parseCMGR("+CMGR: 0,,22\r\n\(ucs2PDU)\r\nOK\r\n") == ucs2PDU,
        "CMGR PDU"
    )
    let cmti = ATResponseParser.parseCMTI("\r\n+CMTI: \"SM\",17\r\n")
    try expect(cmti.count == 1 && cmti[0].storage == "SM" && cmti[0].index == 17, "CMTI")
    try expect(
        ATResponseParser.parseDirectCMT("+CMT: ,22\r\n\(ucs2PDU)\r\n").first == ucs2PDU,
        "direct CMT PDU"
    )
    try expect(
        ATResponseParser.parseCPMSStorage("+CPMS: \"ME\",1,255,\"ME\",1,255\r\nOK") == "ME",
        "CPMS storage"
    )
    try expect(
        ModemMessageStorageCapabilities.readableStorages(
            from: "+CPMS: (\"SM\",\"ME\",\"MT\"),(\"SM\"),(\"SM\",\"ME\")\r\nOK"
        ) == ["SM", "ME", "MT"],
        "CPMS readable storage capabilities"
    )

    var framer = ModemURCStreamFramer()
    try expect(framer.consume("\r\n+CM").messageLocations.isEmpty, "partial CMTI prefix emitted")
    let splitCMTI = framer.consume("TI: \"SM\",17\r\n")
    try expect(
        splitCMTI.messageLocations == [ModemMessageLocation(storage: "SM", index: 17)],
        "split CMTI framing"
    )

    let directPrefix = "+CMT: ,22\r\n\(ucs2PDU)\r\n+CMT: ,22\r\n"
    let firstAndPartialSecond = framer.consume(directPrefix + String(ucs2PDU.prefix(12)))
    try expect(firstAndPartialSecond.directPDUs == [ucs2PDU], "complete CMT before partial CMT was lost")
    let secondCMT = framer.consume(String(ucs2PDU.dropFirst(12)) + "\r\n")
    try expect(secondCMT.directPDUs == [ucs2PDU], "partial second CMT was not retained")

    try expect(
        framer.consume("+CMT: ,22\r\nOK\r\n+CSQ: 20,99\r\n").directPDUs.isEmpty,
        "interleaved command response emitted a direct CMT"
    )
    try expect(
        framer.consume("\(ucs2PDU)\r\n").directPDUs == [ucs2PDU],
        "interleaved command response discarded a pending direct CMT"
    )

    let commandTail = framer.consume("\r\nOK\r\n+CMTI: \"ME\",")
    try expect(commandTail.messageLocations.isEmpty, "partial command-tail CMTI emitted")
    try expect(
        framer.consume("9\r\n").messageLocations == [ModemMessageLocation(storage: "ME", index: 9)],
        "command-tail CMTI was not retained"
    )

    let udhPart2PDU = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0202")
    var bufferedAssembler = BufferedSMSAssembler()
    let bufferedPart1 = bufferedAssembler.ingest([
        ModemStoredPDU(
            index: -1,
            status: 0,
            declaredLength: nil,
            rawPDU: udhPDU,
            storage: nil
        )
    ])
    try expect(bufferedPart1.isEmpty, "incomplete direct multipart SMS was emitted")
    let bufferedComplete = bufferedAssembler.ingest([
        ModemStoredPDU(
            index: -1,
            status: 0,
            declaredLength: nil,
            rawPDU: udhPart2PDU,
            storage: nil
        )
    ])
    try expect(bufferedComplete.count == 1, "multipart SMS did not assemble across URC batches")
    try expect(bufferedComplete.first?.body == "hellohello", "cross-batch multipart SMS body")

    var crossStorageAssembler = BufferedSMSAssembler()
    try expect(
        crossStorageAssembler.ingest([
            ModemStoredPDU(index: 1, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
        ]).isEmpty,
        "cross-storage multipart emitted before completion"
    )
    let crossStorageComplete = crossStorageAssembler.ingest([
        ModemStoredPDU(index: 2, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "ME")
    ])
    try expect(crossStorageComplete.count == 1, "cross-storage multipart did not assemble")
    try expect(
        Set(crossStorageComplete[0].effectiveModemReferences.map(\.storage)) == Set(["SM", "ME"]),
        "cross-storage multipart references were lost"
    )

    var duplicateAssembler = BufferedSMSAssembler()
    let duplicateComplete = duplicateAssembler.ingest([
        ModemStoredPDU(index: 1, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM"),
        ModemStoredPDU(index: 3, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM"),
        ModemStoredPDU(index: 2, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "SM")
    ])
    try expect(
        duplicateComplete.first?.effectiveModemReferences.count == 3,
        "duplicate physical multipart reference was overwritten"
    )

    let deletionOrder = SMSDeletionPlanner.orderedTargets(
        from: duplicateComplete.first?.effectiveModemReferences ?? []
    )
    try expect(
        deletionOrder.map(\.index) == [3, 2, 1],
        "multipart deletion did not order storage indexes from highest to lowest"
    )
    try expect(
        SMSDeletionPlanner.orderedTargets(from: deletionOrder + deletionOrder).count == 3,
        "multipart deletion did not remove duplicate physical references"
    )
    try expect(
        SMSDeletionPlanner.isBareEmptyCMGR(["AT+CMGR=3", "OK"], index: 3),
        "QDC507 bare-OK empty CMGR response was not recognized"
    )
    try expect(
        !SMSDeletionPlanner.isBareEmptyCMGR(["+CMGR: 1,,23", "00AA", "OK"], index: 3),
        "CMGR response containing a PDU was misclassified as empty"
    )

    var expiringAssembler = BufferedSMSAssembler()
    let firstReceipt = Date(timeIntervalSince1970: 1_000)
    _ = expiringAssembler.ingest([
        ModemStoredPDU(index: 8, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
    ], now: firstReceipt)
    let afterRetention = firstReceipt.addingTimeInterval(25 * 60 * 60)
    _ = expiringAssembler.ingest([
        ModemStoredPDU(index: 8, status: 0, declaredLength: nil, rawPDU: udhPDU, storage: "SM")
    ], now: afterRetention)
    try expect(
        expiringAssembler.ingest([
            ModemStoredPDU(index: 9, status: 0, declaredLength: nil, rawPDU: udhPart2PDU, storage: "SM")
        ], now: afterRetention).isEmpty,
        "expired fragment was revived by a periodic CMGL poll"
    )

    let threePart1 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0301")
    let threePart2 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0302")
    let threePart3 = udhPDU.replacingOccurrences(of: "050003CC0201", with: "050003CC0303")
    var rollingExpiryAssembler = BufferedSMSAssembler()
    _ = rollingExpiryAssembler.ingest([
        ModemStoredPDU(index: 20, status: 0, declaredLength: nil, rawPDU: threePart1, storage: "SM")
    ], now: firstReceipt)
    _ = rollingExpiryAssembler.ingest([
        ModemStoredPDU(index: 21, status: 0, declaredLength: nil, rawPDU: threePart2, storage: "SM")
    ], now: firstReceipt.addingTimeInterval(23 * 60 * 60))
    try expect(
        rollingExpiryAssembler.ingest([
            ModemStoredPDU(index: 22, status: 0, declaredLength: nil, rawPDU: threePart3, storage: "SM")
        ], now: afterRetention).isEmpty,
        "a newer fragment kept an expired older fragment alive"
    )

    let duplicateSingles = SMSPDUDecoder.assemble([
        ModemStoredPDU(index: 11, status: 0, declaredLength: nil, rawPDU: ucs2PDU, storage: "SM"),
        ModemStoredPDU(index: 12, status: 0, declaredLength: nil, rawPDU: ucs2PDU, storage: "SM")
    ])
    let mergedDuplicateSingles = SMSMessageMerger.merge(existing: [], incoming: duplicateSingles)
    try expect(mergedDuplicateSingles.messages.count == 1, "duplicate physical single SMS was shown twice")
    try expect(
        mergedDuplicateSingles.messages[0].effectiveModemReferences.count == 2,
        "duplicate physical single SMS reference was lost"
    )

    let storedMessage = SMSMessage(
        id: "stored",
        modemIndices: [7],
        modemStorage: "SM",
        sender: "+123",
        body: "kept",
        timestamp: Date(timeIntervalSince1970: 100),
        rawPDUs: [ucs2PDU],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 100)
    )
    var deletionConfirmation = SMSDeletionConfirmationState()
    deletionConfirmation.request(storedMessage)
    try expect(
        deletionConfirmation.pendingMessageID == storedMessage.id,
        "delete request lost message identity"
    )
    var refreshedStoredMessage = storedMessage
    refreshedStoredMessage.replaceModemReferences(with: [
        ModemPDUReference(
            storedPDU: ModemStoredPDU(
                index: 19,
                status: 1,
                declaredLength: nil,
                rawPDU: ucs2PDU,
                storage: "MT"
            )
        )!,
    ])
    try expect(
        deletionConfirmation.resolve(in: [refreshedStoredMessage])?
            .effectiveModemReferences.first?.index == 19,
        "delete confirmation retained a stale message snapshot"
    )
    deletionConfirmation.cancel()
    try expect(!deletionConfirmation.isPresented, "delete cancel left confirmation presented")
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == nil,
        "delete cancel still returned an identity"
    )
    deletionConfirmation.request(storedMessage)
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == storedMessage.id,
        "delete confirm did not return the requested identity"
    )
    try expect(
        deletionConfirmation.takeConfirmedMessageID(id: storedMessage.id) == nil,
        "delete confirmation could be submitted twice"
    )
    deletionConfirmation.request(storedMessage)
    deletionConfirmation.reconcile(with: [])
    try expect(
        !deletionConfirmation.isPresented,
        "delete confirmation survived removal of its message"
    )
    let unrelatedMessage = SMSMessage(
        id: "new",
        modemIndices: [3],
        modemStorage: "ME",
        sender: "+456",
        body: "new",
        timestamp: Date(timeIntervalSince1970: 200),
        rawPDUs: [gsm7PDU],
        isRead: false,
        firstSeenAt: Date(timeIntervalSince1970: 200)
    )
    let merged = SMSMessageMerger.merge(existing: [storedMessage], incoming: [unrelatedMessage])
    try expect(
        merged.messages.first(where: { $0.id == "stored" })?.modemIndices == [7],
        "incremental merge erased another storage's modem reference"
    )
    let emptyReferenceRefresh = SMSMessage(
        id: "stored",
        modemIndices: [],
        modemStorage: nil,
        sender: storedMessage.sender,
        body: storedMessage.body,
        timestamp: storedMessage.timestamp,
        rawPDUs: storedMessage.rawPDUs,
        isRead: true,
        firstSeenAt: Date(timeIntervalSince1970: 300)
    )
    let refreshed = SMSMessageMerger.merge(existing: [storedMessage], incoming: [emptyReferenceRefresh])
    try expect(refreshed.messages.first?.modemIndices == [7], "empty incremental reference erased stored index")
    try expect(refreshed.messages.first?.modemStorage == "SM", "empty incremental reference erased storage")

    let legacyMessageJSON = """
    {
      "id": "legacy",
      "modemIndices": [7],
      "modemStorage": "SM",
      "sender": "+123",
      "body": "legacy",
      "timestamp": 0,
      "rawPDUs": ["\(ucs2PDU)"],
      "isRead": false,
      "firstSeenAt": 0
    }
    """
    let legacyMessage = try JSONDecoder().decode(
        SMSMessage.self,
        from: Data(legacyMessageJSON.utf8)
    )
    try expect(legacyMessage.modemReferences == nil, "legacy JSON synthesized missing references")
    try expect(legacyMessage.readAt == nil, "legacy JSON synthesized a read timestamp")
    try expect(legacyMessage.effectiveModemReferences.count == 1, "legacy JSON reference fallback")

    var storageSync = MessageStorageSyncTracker()
    try expect(storageSync.markSuccessfulPoll(of: "SM"), "first SM poll was not initial")
    try expect(!storageSync.markSuccessfulPoll(of: "sm"), "second SM poll was treated as initial")
    try expect(storageSync.markSuccessfulPoll(of: "ME"), "first delayed ME poll was not initial")
    storageSync.reset()
    try expect(storageSync.markSuccessfulPoll(of: "SM"), "storage sync reset did not restore initial state")

    let qcsq = ATResponseParser.parseQCSQ("\r\n+QCSQ: \"LTE\",-65,-96,140,-11\r\nOK\r\n")
    try expect(qcsq?.dbm == -96, "QCSQ RSRP")
    try expect(qcsq?.technology == "LTE", "QCSQ RAT")
    try expect(ModemSnapshot().initialSetupState == .insertModule, "setup did not request module")
    let djiUSBConfiguration = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2CA3,0x4006,1,1,1,1,1,0,0\r\nOK"
    )
    try expect(djiUSBConfiguration?.isSafeDJISource == true, "recorded DJI USBCFG parsing")
    try expect(djiUSBConfiguration?.audioEnabled == false, "DJI source audio flag")
    let maVoUSBConfiguration = ATResponseParser.parseUSBConfiguration(
        "+QCFG: \"usbcfg\",0x2C7C,0x125,1,1,1,1,1,0,1\r\nOK"
    )
    try expect(maVoUSBConfiguration?.isMaVoTarget == true, "MaVo target USBCFG parsing")
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 0
        ).initialSetupState == .needsECM,
        "QDC507 usbnet=0 was not classified as needing initialization"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2C7C:0125",
            usbNetMode: 1
        ).initialSetupState == .ready,
        "QDC507 usbnet=1 was not classified as ready"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2CA3:4006",
            usbNetMode: 0,
            usbConfiguration: djiUSBConfiguration
        ).initialSetupState == .needsIdentityConversion,
        "exact DJI identity was not offered one-click conversion"
    )
    try expect(
        ModemSnapshot(
            state: .connected,
            usbIdentity: "2CA3:4006",
            usbNetMode: 0,
            usbConfiguration: ModemUSBConfiguration(
                vendorID: 0x2CA3,
                productID: 0x4006,
                diagnosticEnabled: true,
                nmeaEnabled: true,
                atPortEnabled: true,
                modemEnabled: true,
                networkEnabled: true,
                adbEnabled: true,
                audioEnabled: false
            )
        ).initialSetupState != .needsIdentityConversion,
        "unknown DJI interface tuple was offered conversion"
    )
    try expect(ATResponseParser.parseCSQ("+CSQ: 20,99\r\nOK") == -73, "CSQ conversion")
    try expect(
        ATResponseParser.parseIMSMode("+QCFG: \"ims\",0,1\r\nOK") == 0,
        "IMS mode zero parsing"
    )
    try expect(
        ATResponseParser.parseIMSMode("AT+QCFG=\"ims\"\r\n+QCFG: \"ims\",1,1\r\nOK") == 1,
        "IMS mode one parsing"
    )
    try expect(
        ATResponseParser.parseIMSMode("+QCFG: \"usbnet\",1\r\nOK") == nil,
        "unrelated QCFG parsed as IMS"
    )
    try expect(
        ATResponseParser.parseVoLTEDisabled("+QCFG: \"volte/disable\",0\r\nOK") == false,
        "VoLTE enabled state parsing"
    )
    try expect(
        ATResponseParser.parseVoLTEDisabled("+QCFG: \"volte_disable\",1\r\nOK") == true,
        "VoLTE disabled state parsing"
    )
    try expect(
        ATResponseParser.parseOperator("+COPS: 0,0,\"CHN-CT\",7\r\nOK").name == "中国电信",
        "CHN-CT carrier localization"
    )
    try expect(CarrierNameFormatter.localized("CMCC") == "中国移动", "CMCC localization")
    try expect(CarrierNameFormatter.localized("China Unicom") == "中国联通", "Unicom localization")
    try expect(CarrierNameFormatter.localized("46015") == "中国广电", "Broadnet PLMN localization")
    try expect(
        CarrierNameFormatter.localized("Vodafone UK") == "Vodafone UK",
        "unknown carrier name should be preserved"
    )
    let recoverableNetwork = CellularNetworkStatus(
        isEnabled: true,
        isActive: false,
        isLinkActive: false,
        isHardwarePresent: true
    )
    let recoverableModem = ModemSnapshot(
        state: .connected,
        usbIdentity: "2C7C:0125",
        usbNetMode: 1
    )
    try expect(
        CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "inactive ECM link did not request recovery"
    )
    var activeNetwork = recoverableNetwork
    activeNetwork.isActive = true
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: activeNetwork,
            modem: recoverableModem,
            hasCall: false,
            isInFlight: false,
            completedAttempts: 0
        ),
        "active cellular network requested recovery"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: true,
            isInFlight: false,
            completedAttempts: 0
        ),
        "active call allowed ECM recovery"
    )
    try expect(
        !CellularLinkRecoveryPolicy.shouldAttempt(
            network: recoverableNetwork,
            modem: recoverableModem,
            hasCall: false,
            isInFlight: false,
            completedAttempts: CellularLinkRecoveryPolicy.maximumAttempts
        ),
        "ECM recovery ignored its attempt limit"
    )
    try expect(
        CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 0) == 3_000_000_000 &&
            CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 1) == 15_000_000_000 &&
            CellularLinkRecoveryPolicy.delayNanoseconds(completedAttempts: 2) == 30_000_000_000,
        "ECM recovery backoff changed unexpectedly"
    )

    print("MaVo self-tests passed (calls, PDU/UDH, CMGL/URC framing, buffering, storage, merge).")
} catch {
    fputs("Self-test failed: \(error)\n", stderr)
    exit(1)
}
