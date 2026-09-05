import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
	anchors.fill: parent

	Column {
		width: parent.width
		height: parent.height
		spacing: 8

		// ---------------------------------------------------------------- info
		Rectangle {
			width: 470
			height: 118
			color: "#1c2b3a"
			radius: 5

			Column {
				x: 12; y: 10
				width: parent.width - 24
				spacing: 2

				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 14; font.bold: true
					text: "Secretlab MAGRGB / Nanoleaf Essentials"
				}
				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 11
					textFormat: Text.RichText
					text: "NL72S2 over Nanoleaf extControl v2 &mdash; <b>41 zones</b>, UDP 60222.<br><br>" +
					      "<b>Pairing (once):</b> add the strip by IP below, then in " +
					      "<b>Nanoleaf Desktop</b> select it &rarr; <b>Enable API</b> ON &rarr; " +
					      "<b>Connect to API</b>. This plugin polls for that 30 s window and " +
					      "stores the token itself.<br>" +
					      "Already have a token? Paste it below instead."
				}
			}
		}

		// ---------------------------------------------------------------- manual add
		Rectangle {
			width: 470
			height: 156
			color: "#141414"
			radius: 5

			Column {
				x: 12; y: 8
				spacing: 4

				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 14; font.bold: true
					text: "Add strip by IP address"
				}

				Row {
					spacing: 8

					Rectangle {
						width: 210; height: 32; radius: 5
						color: "#141414"
						border.color: "#1c1c1c"; border.width: 2

						TextField {
							id: discoverIP
							anchors.fill: parent
							leftPadding: 10
							color: theme.primarytextcolor
							font.family: "Poppins"; font.pixelSize: 15
							verticalAlignment: TextInput.AlignVCenter
							placeholderText: "192.168.1.50"
							validator: RegularExpressionValidator {
								regularExpression: /^((?:[0-1]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.){0,3}(?:[0-1]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])$/
							}
							background: Item { }
							onEditingFinished: discovery.forceDiscover(discoverIP.text)
						}
					}

					ToolButton {
						height: 32; width: 110
						font.family: "Poppins"; font.bold: true
						text: "Add"
						onClicked: discovery.forceDiscover(discoverIP.text)
					}

					ToolButton {
						height: 32; width: 110
						font.family: "Poppins"; font.bold: true
						text: "Remove"
						onClicked: discovery.forceDelete(discoverIP.text)
					}
				}

				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 12
					text: "Existing auth token (optional)"
				}

				Row {
					spacing: 8

					Rectangle {
						width: 330; height: 32; radius: 5
						color: "#141414"
						border.color: "#1c1c1c"; border.width: 2

						TextField {
							id: tokenField
							anchors.fill: parent
							leftPadding: 10
							color: theme.primarytextcolor
							font.family: "Poppins"; font.pixelSize: 13
							verticalAlignment: TextInput.AlignVCenter
							placeholderText: "paste token from tools/magrgb-token.json"
							background: Item { }
							onEditingFinished: discovery.setToken(discoverIP.text, tokenField.text)
						}
					}

					ToolButton {
						height: 32; width: 110
						font.family: "Poppins"; font.bold: true
						text: "Save token"
						onClicked: discovery.setToken(discoverIP.text, tokenField.text)
					}
				}
			}
		}

		// ---------------------------------------------------------------- discovered list
		Repeater {
			model: service.controllers

			delegate: Rectangle {
				width: 470
				height: 54
				radius: 5
				color: dev.announced ? "#003EFF" : "#141414"

				property var dev: model.modelData.obj

				Column {
					x: 12; y: 8
					spacing: 2

					Text {
						color: theme.primarytextcolor
						font.family: "Poppins"; font.pixelSize: 14; font.bold: true
						text: dev.name
					}
					Text {
						color: theme.primarytextcolor
						font.family: "Poppins"; font.pixelSize: 11
						text: dev.ip
						      + (dev.token ? "  -  paired" : "  -  waiting for API authorization")
						      + (dev.zones ? "  -  " + dev.zones + " zones" : "")
					}
				}
			}
		}
	}
}
