import QtQuick 2.15
import QtQuick.Controls 2.15

Item {
	anchors.fill: parent

	readonly property int panelWidth: 470
	readonly property int pad: 12

	Column {
		width: parent.width
		spacing: 10

		// ------------------------------------------------------------------ intro
		Rectangle {
			width: panelWidth
			height: introCol.implicitHeight + (pad * 2)
			color: "#1c2b3a"
			radius: 5

			Column {
				id: introCol
				x: pad
				y: pad
				width: parent.width - (pad * 2)
				spacing: 6

				Text {
					width: parent.width
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 14; font.bold: true
					text: "Secretlab MAGRGB — Nanoleaf Essentials"
				}
				Text {
					width: parent.width
					wrapMode: Text.WordWrap
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 11
					textFormat: Text.RichText
					text: "Per-zone streaming over Nanoleaf extControl v2 (UDP 60222). " +
					      "NL72S2 = <b>41 zones</b>.<br><br>" +
					      "<b>Step 1</b> &mdash; enter the strip's IP below and press Add.<br>" +
					      "<b>Step 2</b> &mdash; give it a token, either way:<br>" +
					      "&nbsp;&nbsp;&bull; paste one on the strip's row once it appears, or<br>" +
					      "&nbsp;&nbsp;&bull; in <b>Nanoleaf Desktop</b>: select the strip &rarr; " +
					      "<b>Enable API</b> ON &rarr; <b>Connect to API</b>. This plugin watches for " +
					      "that 30 second window and stores the token by itself.<br><br>" +
					      "Needed once only. The token survives reboots and power cycles."
				}
			}
		}

		// ------------------------------------------------------------------ add by IP
		Rectangle {
			width: panelWidth
			height: addCol.implicitHeight + (pad * 2)
			color: "#141414"
			radius: 5

			Column {
				id: addCol
				x: pad
				y: pad
				width: parent.width - (pad * 2)
				spacing: 8

				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 13; font.bold: true
					text: "Strip IP address"
				}

				Row {
					spacing: 8

					Rectangle {
						width: 200; height: 34; radius: 5
						color: "#1a1a1a"
						border.color: "#2a2a2a"; border.width: 2

						TextField {
							id: discoverIP
							anchors.fill: parent
							anchors.margins: 2
							leftPadding: 8
							color: theme.primarytextcolor
							font.family: "Poppins"; font.pixelSize: 14
							verticalAlignment: TextInput.AlignVCenter
							placeholderText: "192.168.1.50"
							validator: RegularExpressionValidator {
								regularExpression: /^((?:[0-1]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.){0,3}(?:[0-1]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])$/
							}
							background: Item { }
						}
					}

					ToolButton {
						height: 34; width: 100
						font.family: "Poppins"; font.bold: true
						text: "Add"
						onClicked: discovery.forceDiscover(discoverIP.text)
					}

					ToolButton {
						height: 34; width: 100
						font.family: "Poppins"; font.bold: true
						text: "Remove"
						onClicked: discovery.forceDelete(discoverIP.text)
					}
				}

				Text {
					width: parent.width
					wrapMode: Text.WordWrap
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 11
					text: "Each strip keeps its own token — set it on the strip's row below."
				}
			}
		}

		// ------------------------------------------------------------------ devices
		Rectangle {
			width: panelWidth
			height: listCol.implicitHeight + (pad * 2)
			color: "#141414"
			radius: 5

			Column {
				id: listCol
				x: pad
				y: pad
				width: parent.width - (pad * 2)
				spacing: 6

				Text {
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 13; font.bold: true
					text: "Discovered strips"
				}

				Text {
					visible: service.controllers.length === 0
					color: theme.primarytextcolor
					font.family: "Poppins"; font.pixelSize: 11
					text: "none yet — add one by IP above"
				}

				Repeater {
					model: service.controllers

					delegate: Rectangle {
						width: listCol.width
						height: rowCol.implicitHeight + 14
						radius: 5
						color: dev.announced ? "#0b3a6b" : "#1f1f1f"

						property var dev: model.modelData.obj

						Column {
							id: rowCol
							x: 10
							y: 7
							width: parent.width - 20
							spacing: 5

							Text {
								color: theme.primarytextcolor
								font.family: "Poppins"; font.pixelSize: 13; font.bold: true
								text: dev.name
							}
							Text {
								width: parent.width
								wrapMode: Text.WordWrap
								color: theme.primarytextcolor
								font.family: "Poppins"; font.pixelSize: 11
								text: dev.ip
								      + (dev.model ? "   ·   " + dev.model : "")
								      + (dev.token ? "   ·   paired" : "   ·   waiting for API authorization")
								      + (dev.zones ? "   ·   " + dev.zones + " zones" : "")
							}

							// Per-strip token. Tokens are stored keyed by IP, so each strip
							// on the network keeps its own independently.
							Row {
								spacing: 6

								Rectangle {
									width: 250; height: 30; radius: 4
									color: "#141414"
									border.color: "#2a2a2a"; border.width: 1

									TextField {
										id: rowToken
										anchors.fill: parent
										anchors.margins: 2
										leftPadding: 8
										color: theme.primarytextcolor
										font.family: "Poppins"; font.pixelSize: 11
										verticalAlignment: TextInput.AlignVCenter
										placeholderText: dev.token ? "replace this strip's token" : "paste this strip's token"
										background: Item { }
										onAccepted: {
											discovery.setToken(dev.ip, rowToken.text);
											rowToken.text = "";
										}
									}
								}

								ToolButton {
									height: 30; width: 90
									font.family: "Poppins"; font.bold: true
									text: dev.token ? "Replace" : "Save"
									onClicked: {
										discovery.setToken(dev.ip, rowToken.text);
										rowToken.text = "";
									}
								}

								ToolButton {
									height: 30; width: 80
									font.family: "Poppins"; font.bold: true
									text: "Forget"
									onClicked: discovery.forceDelete(dev.ip)
								}
							}
						}
					}
				}
			}
		}
	}
}
